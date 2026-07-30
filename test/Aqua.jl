using Aqua

@testset "Aqua.jl" begin
    Aqua.test_ambiguities(FoodOptimizer)
    Aqua.test_unbound_args(FoodOptimizer)
    Aqua.test_undefined_exports(FoodOptimizer)
    Aqua.test_project_extras(FoodOptimizer)
    Aqua.test_stale_deps(FoodOptimizer)
    Aqua.test_deps_compat(FoodOptimizer)
    Aqua.test_piracies(FoodOptimizer)
    Aqua.test_persistent_tasks(FoodOptimizer)
end
