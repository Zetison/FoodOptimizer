function validate_limits(limits)
    for row ∈ eachrow(limits)
        l = row.Lower
        u = row.Upper

        if !ismissing(l) && !ismissing(u) && l > u
            error(
                "Lower limit ($l) is greater than upper limit ($u) for nutrient $(row.Description)",
            )
        end
    end
end
function extract_limits(limits)
    lower = Dict(zip(limits.Description, limits.Lower))
    upper = Dict(zip(limits.Description, limits.Upper))
    recommended = Dict(zip(limits.Description, limits.Recommended))
    return lower, upper, recommended
end

function slack(c::JuMP.ConstraintRef; atol = 1e-8)
    obj = JuMP.constraint_object(c)
    fval = JuMP.value(obj.func)
    S = obj.set

    if S isa MOI.LessThan
        return S.upper - fval          # >= 0 feasible
    elseif S isa MOI.GreaterThan
        return fval - S.lower          # >= 0 feasible
    elseif S isa MOI.EqualTo
        return abs(fval - S.value)     # == 0 when satisfied
    elseif S isa MOI.Interval
        return min(fval - S.lower, S.upper - fval)  # distance to nearest bound
    else
        error("Unsupported set type: $(typeof(S))")
    end
end

function is_binding(c::JuMP.ConstraintRef; atol = 1e-8)
    return slack(c; atol = atol) <= atol
end

function get_id(foods)
    return foods[!, "Matvare ID"]
end

function get_threshold(config)
    return config["model"]["threshold"]
end

function merge_dfs(foods, foods_extra, keycols)
    extra_cols = setdiff(names(foods_extra), names(foods))
    return leftjoin(
        foods,
        select(foods_extra, vcat(keycols, extra_cols)),
        on = keycols,
        validate = (true, true),
    )
end

function get_energy_maps(config)
    if config["model"]["energy_unit"] == "kcal"
        # Energy content per gram for each nutrient (kcal/g)
        fat_energy = 9
        carb_energy = 4
        protein_energy = 4
        alcohol_energy = 7
    elseif config["model"]["energy_unit"] == "kJ"
        # Energy content per gram for each nutrient (kJ/g)
        fat_energy = 37
        carb_energy = 17
        protein_energy = 17
        alcohol_energy = 29
    else
        error(
            "Invalid energy unit specified in config.yml. Please choose either 'kJ' or 'kcal'.",
        )
    end

    energy_map = Dict(
        "Fett (g)" => fat_energy,
        "Mettede fettsyrer (g)" => fat_energy,
        "C12:0 (laurinsyre) (g)" => fat_energy,
        "C14:0 (myristinsyre) (g)" => fat_energy,
        "C16:0 (palmitinsyre) (g)" => fat_energy,
        "C18:0 (stearinsyre) (g)" => fat_energy,
        "Transfettsyrer (g)" => fat_energy,
        "Enumettede fettsyrer (g)" => fat_energy,
        "C16:1 sum (palmitoleinsyre) (g)" => fat_energy,
        "C18:1 sum (oljesyre) (g)" => fat_energy,
        "Flerumettede fettsyrer (g)" => fat_energy,
        "C18:2n-6 (linolsyre) (g)" => fat_energy,
        "C18:3n-3 (alfalinolensyre) (g)" => fat_energy,
        "C20:3n-3 (eikosatriensyre) (g)" => fat_energy,
        "C20:3n-6 (dihomo-gamma-linolensyre, DGLA) (g)" => fat_energy,
        "C20:4n-3 (eikosatetraensyre) (g)" => fat_energy,
        "C20:4n-6 (arakidonsyre) (g)" => fat_energy,
        "C20:5n-3 (eikosapentaensyre, EPA) (g)" => fat_energy,
        "C22:5n-3 (dokosapentaensyre, DPA) (g)" => fat_energy,
        "C22:6n-3 (dokosaheksaensyre, DHA) (g)" => fat_energy,
        "Omega-3 (g)" => fat_energy,
        "Omega-6 (g)" => fat_energy,
        "Karbohydrat (g)" => carb_energy,
        "Stivelse (g)" => carb_energy,
        "Sukkerarter (g)" => carb_energy,
        "Sukker, tilsatt (g)" => carb_energy,
        "Sukker, fritt (g)" => carb_energy,
        "Protein (g)" => protein_energy,
        "Alkohol (g)" => alcohol_energy,
    )
    main_energy_map = Dict(
        "Fett (g)" => fat_energy,
        "Karbohydrat (g)" => carb_energy,
        "Protein (g)" => protein_energy,
        "Alkohol (g)" => alcohol_energy,
    )
    return energy_map, main_energy_map
end

function _parse_number(numstr::AbstractString)
    s = strip(numstr)
    # Support fractions like "2/3"
    if occursin("/", s)
        parts = split(s, "/"; limit = 2)
        if length(parts) == 2
            a = tryparse(Float64, strip(parts[1]))
            b = tryparse(Float64, strip(parts[2]))
            if a !== nothing && b !== nothing && b != 0
                return a / b
            end
        end
    end
    return tryparse(Float64, s)
end

function _split_terms(side::AbstractString)
    s = strip(side)
    terms = String[]
    buf = IOBuffer()
    depth = 0

    for (i, ch) ∈ enumerate(s)
        if ch == '['
            depth += 1
        elseif ch == ']'
            depth = max(0, depth - 1)
        end

        if depth == 0 && (ch == '+' || ch == '-') && i != 1
            push!(terms, strip(String(take!(buf))))
            write(buf, ch)
        else
            write(buf, ch)
        end
    end

    last_term = strip(String(take!(buf)))
    !isempty(last_term) && push!(terms, last_term)
    return terms
end

function _unwrap_varname(s::AbstractString)
    t = strip(s)
    if startswith(t, "[") && endswith(t, "]")
        return strip(t[2:(end-1)])
    end
    return t
end

function _energy_col_from_epct(varname::AbstractString)
    return replace(varname, r" \(E%\)$" => " (g)")
end

function _parse_linear_side(side::AbstractString, nutrients, intake, energy_map)
    # side = regular_expr + energy_expr / total_energy
    regular_expr = JuMP.AffExpr(0.0)
    energy_expr = JuMP.AffExpr(0.0)
    missing = String[]
    has_regular_var = false
    has_energy_term = false

    for raw_term ∈ _split_terms(side)
        term = strip(raw_term)
        isempty(term) && continue

        sign = 1.0
        if startswith(term, "+")
            term = strip(term[2:end])
        elseif startswith(term, "-")
            sign = -1.0
            term = strip(term[2:end])
        end
        isempty(term) && continue

        # Pure numeric constant
        num = _parse_number(term)
        if num !== nothing
            JuMP.add_to_expression!(regular_expr, sign * num)
            continue
        end

        coeff = 1.0
        varpart = term

        if occursin("*", term)
            parts = split(term, "*"; limit = 2)
            coeff_str = strip(parts[1])
            varpart = strip(parts[2])

            parsed_coeff = _parse_number(coeff_str)
            if parsed_coeff === nothing
                error("Invalid coefficient '$coeff_str' in term '$raw_term'.")
            end
            coeff = parsed_coeff
        end

        varname = _unwrap_varname(varpart)

        # Energy-share terms like [Protein (E%)]
        if endswith(varname, "(E%)")
            col_g = _energy_col_from_epct(varname)
            if !(col_g in nutrients) || !haskey(energy_map, col_g)
                push!(missing, varname)
                continue
            end
            has_energy_term = true
            JuMP.add_to_expression!(
                energy_expr,
                sign * coeff * 100.0 * energy_map[col_g],
                intake[col_g],
            )
            continue
        end

        # Optional direct support for [total_energy]
        if varname == "total_energy"
            JuMP.add_to_expression!(regular_expr, sign * coeff, total_energy)
            has_regular_var = true
            continue
        end

        if !(varname in nutrients)
            push!(missing, varname)
            continue
        end
        has_regular_var = true
        JuMP.add_to_expression!(regular_expr, sign * coeff, intake[varname])
    end

    return regular_expr, energy_expr, unique(missing), has_regular_var, has_energy_term
end

function build_model(foods, nutrients, limits, energy_limits, config)
    lower, upper, recommended = extract_limits(limits)
    threshold = get_threshold(config)
    I = get_id(foods)
    model = JuMP.Model(HiGHS.Optimizer)
    @variable(model, amount[I] >= 0)
    @expression(model, intake[n ∈ nutrients], sum(foods[!, n] .* amount[I]))

    # Energy-share constraints (E%) from `energy_limits`
    energy_lower, energy_upper, energy_recommended = extract_limits(energy_limits)

    energy_map, main_energy_map = get_energy_maps(config)

    # Total energy (kJ): fat + carbs + protein (+ alcohol if present)
    @expression(
        model,
        total_energy,
        sum(kJg * intake[col] for (col, kJg) ∈ main_energy_map if col ∈ nutrients)
    )

    if haskey(config["hard_coded_constraints"], "energy_intake") &&
       !isnothing(config["hard_coded_constraints"]["energy_intake"])
        energy_intake_expr = config["hard_coded_constraints"]["energy_intake"]
        m = match(r"(?i)^\s*(\d+\.?\d*)\s*(kcal|kj)\s*$", energy_intake_expr)

        if m === nothing
            error("Invalid energy_intake format. Example: '2500 kcal'.")
        end

        energy_intake_str, unit = m.captures
        energy_intake = parse(Float64, energy_intake_str)
        if unit == "kcal"
            @constraint(
                model,
                intake["Kilokalorier (kcal)"] == energy_intake,
                base_name = "total_energy"
            )
        elseif unit == "kJ"
            @constraint(
                model,
                intake["Kilojoule (kJ)"] == energy_intake,
                base_name = "total_energy"
            )
        else
            error(
                "Invalid energy_intake unit specified in config.yml. Please choose either 'kJ' or 'kcal'.",
            )
        end
    end

    custom_constraints_path = config["files"]["custom_constraints"]
    custom_constraints = CSV.read(custom_constraints_path, DataFrame)

    # Custom constraints from file
    custom_cons = Dict{String,JuMP.ConstraintRef}()

    for row ∈ eachrow(custom_constraints)
        desc = String(row.Description)
        constraint = String(row.Constraint)

        # Supports <=, >=, ==, =, ≤, ≥, <, >
        m = match(r"^(.*?)(<=|>=|==|=|≤|≥|<|>)(.*)$", constraint)
        if m === nothing
            @warn "Skipping custom constraint with invalid format: '$desc'."
            continue
        end

        lhs_str = strip(m.captures[1])
        op = m.captures[2]
        rhs_str = strip(m.captures[3])

        lhs_reg, lhs_energy, miss_lhs, lhs_has_reg, lhs_has_energy =
            _parse_linear_side(lhs_str, nutrients, intake, energy_map)
        rhs_reg, rhs_energy, miss_rhs, rhs_has_reg, rhs_has_energy =
            _parse_linear_side(rhs_str, nutrients, intake, energy_map)

        missing_vars = unique(vcat(miss_lhs, miss_rhs))
        if !isempty(missing_vars)
            @warn "Skipping custom constraint '$desc' because required nutrients are missing: $(join(missing_vars, ", "))."
            continue
        end

        has_energy_terms = lhs_has_energy || rhs_has_energy

        if has_energy_terms && (lhs_has_reg || rhs_has_reg)
            @warn "Skipping custom constraint '$desc': mixing (E%) terms with non-energy nutrient terms is not supported."
            continue
        end

        diff = if has_energy_terms
            # (A/total_energy) op B  ->  A op B*total_energy  (total_energy >= 0)
            reg_diff = lhs_reg - rhs_reg
            @assert isempty(JuMP.linear_terms(reg_diff)) "Only constants are expected in the regular part of energy-share constraints."
            c = JuMP.constant(reg_diff) # only constants expected here
            (lhs_energy - rhs_energy) + c * total_energy
        else
            lhs_reg - rhs_reg
        end

        if op in ("<=", "≤", "<")
            custom_cons[desc] = @constraint(model, diff <= 0, base_name = desc)
        elseif op in (">=", "≥", ">")
            custom_cons[desc] = @constraint(model, diff >= 0, base_name = desc)
        else # == or =
            custom_cons[desc] = @constraint(model, diff == 0, base_name = desc)
        end
    end

    # Add constraint for unsalted nuts
    I_unsalted_nuts =
        I[occursin.(Ref("Nøtter - usaltet"), coalesce.(foods[!, "Kostholdsgrupper"], ""))]
    lower_limit_unsalted_nuts =
        config["hard_coded_constraints"]["lower_limit_unsalted_nuts"]

    unsalted_nuts_lower_cons = if !isnothing(lower_limit_unsalted_nuts)
        @constraint(
            model,
            100*sum(amount[i] for i ∈ I_unsalted_nuts) >= lower_limit_unsalted_nuts,
            base_name = "Unsalted_nuts_lower",
        )
    end

    # Add constraint for minimum amount of fruit and vegetables (Kostholdsgrupper)
    I_fruit_veg = I[occursin.(
        Ref(r"Frukt og bær|Grønnsaker"),
        coalesce.(foods[!, "Kostholdsgrupper"], ""),
    )]
    lower_limit_fruit_veg = config["hard_coded_constraints"]["lower_limit_fruit_veg"]
    fruit_veg_lower_cons = if !isnothing(lower_limit_fruit_veg)
        @constraint(
            model,
            100*sum(amount[i] for i ∈ I_fruit_veg) >= lower_limit_fruit_veg,
            base_name = "Fruit_veg_lower",
        )
    end

    fruit_to_veg_ratio = config["hard_coded_constraints"]["fruit_to_veg_ratio"]
    I_fruit = I[occursin.(
        Ref(r"Frukt og bær"),
        coalesce.(foods[!, "Kostholdsgrupper"], ""),
    )]
    I_veg = I[occursin.(
        Ref(r"Grønnsaker"),
        coalesce.(foods[!, "Kostholdsgrupper"], ""),
    )]
    fruit_to_veg_ratio_cons = if !isnothing(fruit_to_veg_ratio)
        @constraint(
            model,
            100*sum(amount[i] for i ∈ I_fruit) >=
            fruit_to_veg_ratio *
            100 * sum(amount[i] for i ∈ I_veg),
            base_name = "Fruit_to_veg_ratio",
        )
    end

    lower_number_of_fruits = config["hard_coded_constraints"]["lower_number_of_fruits"]
    lower_number_of_vegetables =
        config["hard_coded_constraints"]["lower_number_of_vegetables"]
    I_fruit_veg = I[occursin.(
        Ref(r"Frukt og bær|Grønnsaker"),
        coalesce.(foods[!, "Kostholdsgrupper"], ""),
    )]
    @expression(model, total_fruit_veg_amount, sum(amount[j] for j ∈ I_fruit_veg))
    if !isnothing(lower_number_of_fruits)
        I_fruit = I[occursin.(
            Ref(r"Frukt og bær"),
            coalesce.(foods[!, "Kostholdsgrupper"], ""),
        )]
        @variable(model, used_fruits[I_fruit], Bin)
        M_fruit_share = 10.0 # = 0.1 * max total_fruit_veg_amount, with total amount capped at 100
        @constraint(
            model,
            [i ∈ I_fruit],
            amount[i] + M_fruit_share * (1 - used_fruits[i]) >=
            0.1 * total_fruit_veg_amount,
            base_name = "fruit_used_lower"
        )
        @constraint(
            model,
            [i ∈ I_fruit],
            amount[i] <= 100.0 * used_fruits[i],
            base_name = "fruit_used_upper"
        )
        @constraint(
            model,
            sum(used_fruits[i] for i ∈ I_fruit) >= lower_number_of_fruits,
            base_name = "lower_number_of_fruits"
        )
    end

    if !isnothing(lower_number_of_vegetables)
        I_veg = I[occursin.(
            Ref(r"Grønnsaker"),
            coalesce.(foods[!, "Kostholdsgrupper"], ""),
        )]
        @variable(model, used_veg[I_veg], Bin)
        M_veg_share = 10.0 # = 0.1 * max total_fruit_veg_amount, with total amount capped at 100

        @constraint(
            model,
            [i ∈ I_veg],
            amount[i] + M_veg_share * (1 - used_veg[i]) >= 0.1 * total_fruit_veg_amount,
            base_name = "veg_used_lower"
        )
        @constraint(
            model,
            [i ∈ I_veg],
            amount[i] <= 100.0 * used_veg[i],
            base_name = "veg_used_upper"
        )
        @constraint(
            model,
            sum(used_veg[i] for i ∈ I_veg) >= lower_number_of_vegetables,
            base_name = "lower_number_of_vegetables"
        )
    end

    # Add: lower <= 100 * nutrient_energy / total_energy <= upper
    energy_desc = energy_limits.Description
    energy_col = Dict(d => replace(d, r" \(E%\)" => " (g)") for d ∈ energy_desc)
    energy_kJg = Dict(d => energy_map[energy_col[d]] for d ∈ energy_desc)

    # Set lower bounds for each energy share
    energy_desc_lower = [d for d ∈ energy_desc if !ismissing(energy_lower[d])]
    energy_lower_cons = if !isempty(energy_desc_lower)
            @constraint(
            model,
            [d ∈ energy_desc_lower],
            100.0 * energy_kJg[d] * intake[energy_col[d]] ≥ energy_lower[d] * total_energy,
            base_name = "energy_lower",
        )
    end

    # Add: lower <= 100 * nutrient_energy / total_energy <= upper
    energy_desc_upper = [d for d ∈ energy_desc if !ismissing(energy_upper[d])]
    energy_upper_cons = if !isempty(energy_desc_upper)
            @constraint(
            model,
            [d ∈ energy_desc_upper],
            100.0 * energy_kJg[d] * intake[energy_col[d]] ≤ energy_upper[d] * total_energy,
            base_name = "energy_upper",
        )
    end

    # Set lower bounds for each food item
    nutrients_lower = [n for n ∈ nutrients if !ismissing(lower[n])]
    lower_cons = if !isempty(nutrients_lower)
            @constraint(
            model,
            [n ∈ nutrients_lower],
            lower[n] ≤ intake[n],
            base_name = "nutrient_lower",
        )
    end

    # Set upper bounds for each food item
    nutrients_upper = [n for n ∈ nutrients if !ismissing(upper[n])]

    upper_cons = if !isempty(nutrients_upper)
            @constraint(
            model,
            [n ∈ nutrients_upper],
            intake[n] ≤ upper[n],
            base_name = "nutrient_upper",
        )
    end

    food_lower = Dict(zip(I, foods.Lower))
    food_upper = Dict(zip(I, foods.Upper))
    I_food_lower = [i for i ∈ I if !ismissing(food_lower[i])]
    I_food_upper = [i for i ∈ I if !ismissing(food_upper[i])]

    food_lower_cons = if !isempty(I_food_lower)
        @constraint(
            model,
            [i ∈ I_food_lower],
            food_lower[i] ≤ amount[i],
            base_name = "food_lower"
        )
    else
        []
    end

    food_upper_cons = if !isempty(I_food_upper)
        @constraint(
            model,
            [i ∈ I_food_upper],
            amount[i] ≤ food_upper[i],
            base_name = "food_upper"
        )
    else
        []
    end

    # Add constraints for food item limit if specified in the config
    food_item_limit = config["hard_coded_constraints"]["food_item_limit"]
    if food_item_limit > 0
        @variable(model, used[I], Bin)
        @constraint(
            model,
            [i ∈ I],
            amount[i] >= threshold * used[i],
            base_name = "food_used_lower"
        )
        M = Dict(i => ismissing(food_upper[i]) ? 100.0 : food_upper[i] for i ∈ I)
        @constraint(
            model,
            [i ∈ I],
            amount[i] <= M[i] * used[i],
            base_name = "food_used_upper"
        )
        @constraint(
            model,
            sum(used[i] for i ∈ I) <= food_item_limit,
            base_name = "food_item_limit"
        )
    end

    amount_cons =
        @constraint(model, sum(amount[i] for i ∈ I) ≤ 100.0, base_name = "amount") # Daily intak of food and water are limited to 10kg (100.0*100g)

    # Store all constraints in a dictionary for easy access
    model[:cons] = Dict()
    model[:cons][:energy_lower] = zip(energy_desc_lower, energy_lower_cons)
    model[:cons][:energy_upper] = zip(energy_desc_upper, energy_upper_cons)
    model[:cons][:nutrient_lower] = zip(nutrients_lower, lower_cons)
    model[:cons][:nutrient_upper] = zip(nutrients_upper, upper_cons)
    model[:cons][:food_lower] = zip(I_food_lower, food_lower_cons)
    model[:cons][:food_upper] = zip(I_food_upper, food_upper_cons)
    model[:cons][:unsalted_nuts_lower] = unsalted_nuts_lower_cons
    model[:cons][:fruit_veg_lower] = fruit_veg_lower_cons
    model[:cons][:fruit_to_veg_ratio] = fruit_to_veg_ratio_cons
    model[:cons][:custom] = custom_cons
    model[:cons][:amount] = amount_cons

    # Minimize number of ingredients, cost and salt
    #@objective(model, Min, sum(used[I]) + sum(amount[I]*100 .* foods[!, "Pris (kr/kg)"]/1000))
    if config["model"]["objective"] == "cost"
        @objective(model, Min, sum(amount[I]*100 .* foods[!, "Pris (kr/kg)"]/1000))
    elseif config["model"]["objective"] == "RI"
        food_recommended = Dict(zip(I, foods.Recommended))
        I_w_recommended = filter(i -> !ismissing(food_recommended[i]), I)
        nutrients_w_recommended = filter(n -> !ismissing(recommended[n]), nutrients)
        energy_w_recommended = filter(d -> !ismissing(energy_recommended[d]), energy_desc)
        @variable(model, deviation[n ∈ nutrients_w_recommended] >= 0)
        @variable(model, deviation_foods[i ∈ I_w_recommended] >= 0)
        @variable(model, deviation_energy[d ∈ energy_w_recommended] >= 0)

        @constraint(
            model,
            [n ∈ nutrients_w_recommended],
            deviation[n] >= intake[n] - recommended[n],
            base_name = "deviation_nutrient"
        )
        @constraint(
            model,
            [n ∈ nutrients_w_recommended],
            deviation[n] >= recommended[n] - intake[n],
            base_name = "deviation_nutrient"
        )
        @constraint(
            model,
            [i ∈ I_w_recommended],
            deviation_foods[i] >= amount[i] - food_recommended[i],
            base_name = "deviation_foods"
        )
        @constraint(
            model,
            [i ∈ I_w_recommended],
            deviation_foods[i] >= food_recommended[i] - amount[i],
            base_name = "deviation_foods"
        )
        @constraint(
            model,
            [d ∈ energy_w_recommended],
            deviation_energy[d] >=
            100.0 * energy_kJg[d] * intake[energy_col[d]] -
            energy_recommended[d] * total_energy,
            base_name = "deviation_energy"
        )
        @constraint(
            model,
            [d ∈ energy_w_recommended],
            deviation_energy[d] >=
            energy_recommended[d] * total_energy -
            100.0 * energy_kJg[d] * intake[energy_col[d]],
            base_name = "deviation_energy"
        )

        @objective(
            model,
            Min,
            sum(
                deviation[n] / (iszero(recommended[n]) ? 1.0 : recommended[n]) for
                n ∈ nutrients_w_recommended
            ) +
            sum(
                deviation_foods[i] /
                (iszero(food_recommended[i]) ? 1.0 : food_recommended[i]) for
                i ∈ I_w_recommended
            ) +
            sum(
                deviation_energy[d] /
                (iszero(energy_recommended[d]) ? 1.0 : energy_recommended[d]) for
                d ∈ energy_w_recommended
            )
        )
    else
        error(
            "Invalid objective specified in config.yml. Please choose either 'cost' or 'RI'.",
        )
    end

    if config["model"]["write_lp_to_file"]
        JuMP.write_to_file(model, config["model"]["lp_output_file"])
    end

    return model
end

function print_optional_amounts(model, foods, config)
    threshold = get_threshold(config)
    I = get_id(foods)
    deviation_foods =
        haskey(JuMP.object_dictionary(model), :deviation_foods) ? model[:deviation_foods] :
        nothing
    food_amounts = DataFrame(
        [
            (
                foods[I .== i, "Matvare"][1],
                100 * value(model[:amount][i]),
                deviation_foods !== nothing && (i in deviation_foods.axes[1]) ?
                value(deviation_foods[i]) : missing,
            ) for i ∈ I if value(model[:amount][i]) > threshold
        ],
        ["Food", "Amount (g)", "Deviation"],
    )
    sort!(food_amounts, "Amount (g)", rev = true)
    total_weight = sum(value.(model[:amount][I])) * 100
    if config["io"]["print_food_amounts"]
        @printf("\nOptimal food amounts:\n")
        pretty_table(food_amounts; alignment = [:l, :r, :r])

        @printf("Total weight per day: %.2f g\n\n", total_weight)
    end
    return food_amounts
end

function print_energy_summary(model, foods, energy_limits, config)
    energy_lower, energy_upper, energy_recommended = extract_limits(energy_limits)
    energy_desc = energy_limits.Description
    energy_col = Dict(d => replace(d, r" \(E%\)" => " (g)") for d ∈ energy_desc)
    energy_map, _ = get_energy_maps(config)
    I = get_id(foods)

    energy_summary = DataFrame(
        [
            (
                d,
                value(
                    100.0 *
                    energy_map[energy_col[d]] *
                    sum(foods[!, energy_col[d]] .* model[:amount][I]) /
                    value(model[:total_energy]),
                ),
                energy_lower[d],
                energy_upper[d],
                energy_recommended[d],
            ) for d ∈ energy_desc
        ],
        [
            "Energy Source",
            "Energy Share (%)",
            "Lower Limit (%)",
            "Upper Limit (%)",
            "Recommended (%)",
        ],
    )

    if config["io"]["print_energy_summary"]
        @printf("Energy summary:\n")
        pretty_table(energy_summary; alignment = [:l, :r, :r, :r, :r])
    end
    return energy_summary
end

function print_nutrient_summary(model, foods, nutrients, limits, config)
    lower, upper, recommended = extract_limits(limits)
    I = get_id(foods)
    nutrient_summary = DataFrame(
        [
            (
                n,
                sum(foods[!, n] .* value.(model[:amount][I])),
                lower[n],
                upper[n],
                recommended[n],
                (
                    !ismissing(recommended[n]) &&
                    haskey(JuMP.object_dictionary(model), :deviation)
                ) ?
                value(model[:deviation][n]) : missing,
            ) for n ∈ nutrients
        ],
        [:Nutrient, :Total, :Lower, :Upper, :Recommended, :Deviation],
    )

    if config["io"]["print_nutrient_summary"]
        @printf("Nutrient summary:\n")
        pretty_table(nutrient_summary; alignment = [:l, :r, :r, :r, :r, :r])
    end
    return nutrient_summary
end

function calc_scaled_foods(model, foods, nutrients, config)
    threshold = get_threshold(config)
    I = get_id(foods)
    selected_ids = [i for i ∈ I if value(model[:amount][i]) > threshold]
    scaled_foods = foods[findall(in(selected_ids), I), :]
    scaled_foods = deepcopy(scaled_foods)
    scaled_foods[!, "Amount (g)"] = [100 * value(model[:amount][i]) for i ∈ selected_ids]

    for n ∈ nutrients
        scaled_foods[!, n] .*= scaled_foods[!, "Amount (g)"] ./ 100
    end

    sort!(scaled_foods, "Amount (g)")
    food_lower = Dict(zip(I, foods.Lower))
    food_upper = Dict(zip(I, foods.Upper))
    food_recommended = Dict(zip(I, foods.Recommended))

    scaled_foods[!, "Lower"] = [food_lower[i] for i ∈ scaled_foods[!, "Matvare ID"]]
    scaled_foods[!, "Upper"] = [food_upper[i] for i ∈ scaled_foods[!, "Matvare ID"]]
    scaled_foods[!, "Recommended"] =
        [food_recommended[i] for i ∈ scaled_foods[!, "Matvare ID"]]

    # Dual-like value for each food decision variable (LP reduced cost)
    if config["hard_coded_constraints"]["food_item_limit"] > 0
        @warn "Dual values for food items are not available when a food item limit is set."
        columns = ["Matvare", "Amount (g)", "Lower", "Upper", "Recommended", nutrients...]

    else
        scaled_foods[!, "Dual"] =
            [JuMP.reduced_cost(model[:amount][i]) for i ∈ scaled_foods[!, "Matvare ID"]]
        columns =
            ["Matvare", "Amount (g)", "Dual", "Lower", "Upper", "Recommended", nutrients...]
    end
    select!(scaled_foods, columns)
    sort!(scaled_foods, "Amount (g)", rev = true)
    return scaled_foods
end

function print_scaled_foods(scaled_foods, foods, model, config)
    if config["io"]["print_scaled_foods"]
        I = get_id(foods)
        if "Pris (kr/kg)" in names(foods)
            @printf(
                "\nTotal cost per day: %.2f NOK\n",
                sum(value.(model[:amount][I]) * 100 .* foods[!, "Pris (kr/kg)"] / 1000),
            )
        end
        pretty_table(scaled_foods; alignment = :l, backend = :text)
    end
end

function print_constraints(model, config)
    binding_only = config["io"]["print_binding_only"]
    if config["io"]["print_constraints"]
        if binding_only
            println("\nBinding constraints:")
        else
            println("\nAll constraints:")
        end
        constraint_df =
            DataFrame(Item = String[], Type = String[], Slack = Float64[], Binding = Bool[])

        for (label, cons_zip) ∈ (
            ("lower", model[:cons][:energy_lower]),
            ("upper", model[:cons][:energy_upper]),
            ("lower", model[:cons][:nutrient_lower]),
            ("upper", model[:cons][:nutrient_upper]),
            ("lower", model[:cons][:food_lower]),
            ("upper", model[:cons][:food_upper]),
            ("lower", [("Unsalted nuts", model[:cons][:unsalted_nuts_lower])]),
            ("lower", [("Fruit and vegetables", model[:cons][:fruit_veg_lower])]),
            ("lower", [("Fruit to vegetable ratio", model[:cons][:fruit_to_veg_ratio])]),
            ("custom", model[:cons][:custom]),
            ("upper", [("Total amount", model[:cons][:amount])]),
        )
            if cons_zip === nothing
                continue
            end
            for (n, c) ∈ cons_zip
                if c === nothing
                    continue
                end
                push!(
                    constraint_df,
                    (
                        Item = string(n),
                        Type = label,
                        Slack = slack(c),
                        Binding = is_binding(c),
                    ),
                )
            end
        end
        if binding_only
            constraint_df = constraint_df[constraint_df.Binding .== true, :]
            select!(constraint_df, Not(:Binding))
            select!(constraint_df, Not(:Slack))
            aligment = [:l, :l]
        else
            aligment = [:l, :l, :r, :c]
        end
        sort!(constraint_df, "Binding", rev = true)

        pretty_table(constraint_df; alignment = aligment)
    end
end

function export_results_to_excel(
    food_amounts,
    energy_summary,
    nutrient_summary,
    scaled_foods,
    config,
)
    if config["io"]["write_results_to_excel"]
        XLSX.writetable(
            config["io"]["excel_output_file"],
            "food_amounts" => food_amounts,
            "energy_summary" => energy_summary,
            "nutrient_summary" => nutrient_summary,
            "scaled_foods" => scaled_foods;
            overwrite = true,
        )
    end
end
