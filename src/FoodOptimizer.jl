# Run with `julia --project=. FoodOptimizer.jl` to install dependencies and run the optimization.
module FoodOptimizer
using JuMP
using HiGHS
using DataFrames
using CSV
using CPLEX
using XLSX
using Printf
using YAML
using PrettyTables
import MathOptInterface as MOI

include("utils.jl")

function main()
    config = YAML.load_file("config.yml")

    foods_path = config["files"]["foods"]
    foods_extra_path = config["files"]["foods_extra"]
    food_limits_path = config["files"]["food_limits"]

    foods = CSV.read(foods_path, DataFrame; types = Dict("Matvare ID" => String))
    foods_extra =
        CSV.read(foods_extra_path, DataFrame; types = Dict("Matvare ID" => String))
    food_limits =
        CSV.read(food_limits_path, DataFrame; types = Dict("Matvare ID" => String))

    keycols = ["Matvare ID", "Matvare"]
    foods = merge_dfs(foods, food_limits, keycols)

    nutrients = setdiff(
        names(foods),
        [
            "Matvare ID",
            "Matvare",
            "Lower",
            "Upper",
            "Recommended",
            "Pris (kr/kg)",
            "Kategori",
            "Kostholdsgrupper",
            "FoodEx2-klassifisering",
        ],
    )

    # Align schema before appending rows from foods_extra
    for col ∈ setdiff(names(foods), names(foods_extra))
        foods_extra[!, col] = fill(missing, nrow(foods_extra))
    end

    foods_extra = select(foods_extra, names(foods))
    append!(foods, foods_extra; cols = :setequal, promote = true)

    # Exclude foods based on FoodEx2 groups specified in the config
    for group ∈ config["model"]["exclude_foodex2_groups"]
        foods = filter(
            row ->
                ismissing(row["FoodEx2-klassifisering"]) ||
                !occursin(group, row["FoodEx2-klassifisering"]),
            foods,
        )
    end

    # Exclude foods based on categories specified in the config
    for category ∈ config["model"]["exclude_categories"]
        foods = filter(
            row -> ismissing(row["Kategori"]) || !occursin(category, row["Kategori"]),
            foods,
        )
    end

    # Remove columns that are entirely missing from foods_extra
    missing_only_cols =
        [c for c ∈ names(foods_extra) if eltype(foods_extra[!, c]) <: Missing]
    select!(foods_extra, Not(missing_only_cols))

    @assert nrow(unique(select(foods, keycols))) == nrow(foods) "foods has duplicate key rows."
    @assert nrow(unique(select(foods_extra, keycols))) == nrow(foods_extra) "foods_extra has duplicate key rows."

    for col ∈ nutrients
        if !(eltype(foods[!, col]) <: Missing)
            replace!(foods[!, col], missing => 0, "" => 0)
            foods[!, col] = identity.(foods[!, col]) # Reinfer column types after replacing missing values
        end
    end

    limits_path = config["files"]["nutrient_limits"]
    limits = CSV.read(limits_path, DataFrame)
    validate_limits(limits)
    @assert Set(nutrients) == Set(limits.Description) "Nutrients in $foods_path and $limits_path do not match."

    energy_limits_path = config["files"]["energy_limits"]
    energy_limits = CSV.read(energy_limits_path, DataFrame)
    validate_limits(energy_limits)

    model = build_model(foods, nutrients, limits, energy_limits, config)

    solver = lowercase(String(config["model"]["solver"]))
    if solver == "highs"
        set_optimizer(model, HiGHS.Optimizer)
    elseif solver == "cplex"
        set_optimizer(model, CPLEX.Optimizer)
    else
        error(
            "Unsupported solver in config[\"model\"][\"solver\"]: $(config["model"]["solver"]). Use \"HiGHS\" or \"CPLEX\".",
        )
    end

    optimize!(model)
    if termination_status(model) == MOI.OPTIMAL
        println("Objective value: ", objective_value(model))
    else
        error("Optimization failed with status: ", termination_status(model))
    end

    food_amounts = print_optional_amounts(model, foods, config)
    energy_summary = print_energy_summary(model, foods, energy_limits, config)
    nutrient_summary = print_nutrient_summary(model, foods, nutrients, limits, config)
    scaled_foods = calc_scaled_foods(model, foods, nutrients, config)
    print_scaled_foods(scaled_foods, foods, model, config)
    print_constraints(model, config)

    export_results_to_excel(
        food_amounts,
        energy_summary,
        nutrient_summary,
        scaled_foods,
        config,
    )
end

export main, build_model, calc_scaled_foods
export print_optional_amounts, print_nutrient_summary, print_energy_summary
export print_scaled_foods, print_constraints, validate_limits
export export_results_to_excel
export slack,
    is_binding,
    get_id,
    get_threshold,
    merge_dfs,
    extract_limits,
    get_energy_maps
end
