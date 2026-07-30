using Test

pkg_dir = pkgdir(FoodOptimizer)
testdir = joinpath(pkg_dir, "test")

@testset "FoodOptimizer" begin
    # Run all Aqua tests
    include(joinpath(testdir, "Aqua.jl"))

    # Check if there is need for formatting
    include(joinpath(testdir, "JuliaFormatter.jl"))
end
