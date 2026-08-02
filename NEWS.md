# Release Notes

## Version 0.1.2 (2026-08-02)

### Bugfix

* Fixed an issue when binary variables were present even though `food_item_limit` was set to 0. The code now correctly checks for the presence of binary variables using `JuMP.is_binary` instead of relying on the `food_item_limit` parameter.

## Version 0.1.1 (2026-08-02)

### Bugfix

* Enabled the use of `null` for `lower_limit_unsalted_nuts`, `lower_limit_fruit_veg`, `fruit_to_veg_ratio`, `lower_number_of_fruits`, and `lower_number_of_vegetables` in the configuration file. Previously, these parameters were incorrectly treated as mandatory, causing errors when set to `null`.

## Version 0.1.0 (2026-08-02)

First public release of the Food Optimizer package.