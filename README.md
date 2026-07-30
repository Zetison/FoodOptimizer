# FoodOptimizer

Optimize daily food intake using nutrient requirements, food-specific limits, energy-share constraints (E%), and custom linear dietary constraints.

## Installation

Clone the repository and activate the project environment:

```bash
julia --project=.
```

Run interactively:

```julia
using Revise
using FoodOptimizer

main()
```

Or run directly:

```bash
julia --project=. -e 'using FoodOptimizer; FoodOptimizer.main()'
```

## Configuration

All file locations, optimisation settings, objectives and output options are configured through `config.yml`.

Typical configuration options include:

```yaml
model:
  objective: RI
  energy_unit: kJ
  energy_intake: 2500 kcal
  food_item_limit: 10
  threshold: 0.01
```

## Input Files

The optimiser uses the following input files:

| File | Purpose |
|------|---------|
| `matvaretabellen_2026_complete.csv` | Main food database containing nutrient content per 100 g edible portion. |
| `matvaretabellen_extra.csv` | Additional user-defined foods not present in the main database. |
| `food_limits.csv` | Optional lower bounds, upper bounds and recommended amounts for individual foods. |
| `nutrient_limits.csv` | Lower bounds, upper bounds and recommended intake levels for nutrients. |
| `energy_limits.csv` | Lower bounds, upper bounds and recommended energy shares (E%). |
| `custom_constraints.csv` | Additional custom dietary constraints expressed as linear equations or inequalities. |

### Main Food Database

Each row in the food database represents a food identified by a unique `Matvare ID`.

Nutrient values are specified per 100 g edible portion.

### Additional Foods

Additional foods may be added through `matvaretabellen_extra.csv`.

Example:

```csv
Matvare ID,Matvare,Kalsium (Ca) (mg),Jod (I) (µg)
99.001,"Svensk salt, bordsalt, jodert, Jozo",10,5000
```

Columns missing from `matvaretabellen_extra.csv` are automatically added during import.

### Nutrient Limits

Nutrient requirements are configured in `nutrient_limits.csv`:

```csv
Description,Lower,Upper,Recommended
Protein (g),52.8,135,66.4
Vitamin B12 (kobalamin) (µg),2,,4
Salt (NaCl) (g),0,5.75,
```

Rules:

- `Lower` defines a minimum intake.
- `Upper` defines a maximum intake.
- `Recommended` is used only by the `RI` objective.
- Empty cells disable the corresponding constraint.

### Food Limits

Food-specific limits are configured in `food_limits.csv`:

```csv
Matvare ID,Matvare,Lower,Upper,Recommended
99.001,"Svensk salt, bordsalt, jodert, Jozo",,,0
```

Rules:

- `Lower` defines a minimum amount.
- `Upper` defines a maximum amount.
- `Recommended` is used by the `RI` objective.
- Amounts are expressed in model units of 100 g.

Example:

```text
1.5 = 150 g/day
```

### Energy Share Constraints (E%)

Energy-share constraints are defined in `energy_limits.csv`.

Example:

```csv
Description,Lower,Upper,Recommended
Fett (E%),25,40,32.5
Karbohydrat (E%),45,60,52.5
Protein (E%),10,20,15
```

FoodOptimizer calculates energy shares from fat, carbohydrates, protein and alcohol using configurable energy factors:

| Nutrient | kcal/g | kJ/g |
|-----------|---------|-------|
| Fat | 9 | 37 |
| Carbohydrate | 4 | 17 |
| Protein | 4 | 17 |
| Alcohol | 7 | 29 |

The unit is selected through:

```yaml
model:
  energy_unit: kJ
```

or

```yaml
model:
  energy_unit: kcal
```

## Custom Constraints

Additional constraints may be defined in `custom_constraints.csv`.

Example:

```csv
Description,Constraint
Andel umettede fettsyrer,[Enumettede fettsyrer (g)]+[Flerumettede fettsyrer (g)]>=2/3*[Fett (g)]
Tilsatt og fritt sukker,[Sukker, tilsatt (E%)]+[Sukker, fritt (E%)]<10
```

Supported operators:

```text
<=
>=
<
>
=
==
≤
≥
```

Supported syntax:

```text
[Nutrient]
coefficient*[Nutrient]
constant
fractions such as 2/3
```

Energy-share variables may be referenced using:

```text
[Fett (E%)]
[Protein (E%)]
```

The special variable

```text
[total_energy]
```

is also supported.

Mixing E% terms and ordinary nutrient variables within the same custom constraint is not supported.

## Objective Functions

### Cost Minimisation

```yaml
model:
  objective: cost
```

Minimises total food cost while satisfying all constraints.

### Recommended Intake (RI)

```yaml
model:
  objective: RI
```

Minimises normalised absolute deviation from:

- nutrient recommendations in `nutrient_limits.csv`
- food recommendations in `food_limits.csv`
- energy share recommendations in `energy_limits.csv`

while satisfying all lower and upper bounds.

## Limiting the Number of Foods

The number of selected foods can be restricted:

```yaml
model:
  food_item_limit: 10
  threshold: 0.01
```

When `food_item_limit > 0`, binary decision variables are introduced and the optimiser can select at most the specified number of foods.

Foods with amounts below `threshold` are treated as not selected.

## Outputs

The optimiser can generate:

- optimal food amounts
- energy-share summary
- nutrient summary
- scaled nutrient contribution per selected food
- binding constraint report
- total daily cost
- reduced costs for selected foods (LP models only)

Results may optionally be exported to Excel:

```yaml
io:
  write_results_to_excel: true
```

Sheets:

- `food_amounts`
- `energy_summary`
- `nutrient_summary`
- `scaled_foods`

## Creating the Matvaretabellen CSV

From the Matvaretabellen 2026 Excel workbook, export the sheet:

```text
Matvarer (alle næringsstoffer)
```

Remove category header rows such as:

```text
Grønnsaker
Drikke
Frukt
```

and export the remaining data to CSV.

If values are stored with decimal commas, convert them prior to export. One approach is to create a helper sheet using:

```excel
=NUMBERVALUE('Matvarer (alle næringsstoffer)'!C2, ",", " ")
```

and copy the formula over all numeric cells.

## Disclaimer

This software is intended for educational, research and informational purposes only.

It is not a substitute for professional dietary, nutritional or medical advice.

## References

1. Helsedirektoratet. Referanseverdier for energi og næringsstoffer. https://www.helsedirektoratet.no/rapporter/referanseverdier-for-energi-og-naeringsstoffer
2. Matvaretabellen 2026. Mattilsynet. https://www.matvaretabellen.no
