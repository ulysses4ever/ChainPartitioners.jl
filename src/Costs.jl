abstract type AbstractOracleCost{Mdl} end

function oracle_stripe(mdl, A, Π; kwargs...)
    return oracle_stripe(mdl, A; kwargs...)
end

function bound_stripe(A, K, Π, ocl::AbstractOracleCost)
    return bound_stripe(A, K, Π, oracle_model(ocl))
end

function bound_stripe(A, K, ocl::AbstractOracleCost)
    return bound_stripe(A, K, oracle_model(ocl))
end

function bound_stripe(A, K, Π, mdl)
    return bound_stripe(A, K, mdl)
end

@inline cost_type(mdl) = cost_type(typeof(mdl))
@inline cost_type(::Type) = error()
@inline cost_type(::Type{<:AbstractOracleCost{Mdl}}) where {Mdl} = cost_type(Mdl)
@inline objective_identity(::typeof(+), T) = zero(T)
@inline objective_identity(::typeof(max), T) = typemin(T)

@inline bottleneck_value(A, Π, Φ, mdl) = compute_objective(max, A, Π, Φ, mdl)
@inline bottleneck_value(A, Φ, mdl) = compute_objective(max, A, Φ, mdl)
@inline total_value(A, Π, Φ, mdl) = compute_objective(+, A, Π, Φ, mdl)
@inline total_value(A, Φ, mdl) = compute_objective(+, A, Φ, mdl)

@inline function compute_objective(g, A, Π, Φ, mdl)
    return compute_objective(g, A, Π, Φ, oracle_stripe(mdl, A, Π))
end
function compute_objective(g::G, A, Π, Φ, mdl::AbstractOracleCost) where {G}
    cst = objective_identity(g, cost_type(mdl))
    for k = 1:Φ.K
        j = Φ.spl[k]
        j′ = Φ.spl[k + 1]
        cst = g(cst, mdl(j, j′, k))
    end
    return cst
end
@inline function compute_objective(g, A, Φ, mdl)
    return compute_objective(g, A, Φ, oracle_stripe(mdl, A))
end
function compute_objective(g, A, Φ::SplitPartition, mdl::AbstractOracleCost) where {G}
    cst = objective_identity(g, cost_type(mdl))
    for k = 1:Φ.K
        j = Φ.spl[k]
        j′ = Φ.spl[k + 1]
        cst = g(cst, mdl(j, j′, k))
    end
    return cst
end



struct ConstrainedCost{F, W, T}
    f::F
    w::W
    w_max::T
end

cost_type(::Type{ConstrainedCost{F, W, T}}) where {F, W, T} = cost_type(F)

struct ConstrainedCostOracle{F, W, T}
    f::F
    w::W
    w_max::T
end

oracle_model(ocl::WorkCostOracle) = ConstrainedCost(oracle_model(ocl.f), oracle_model(ocl.w), ocl.w_max)

function oracle_stripe(cst::ConstrainedCost, A::SparseMatrixCSC, args...; kwargs...)
    return ConstrainedCostOracle(oracle_stripe(cst.f, A, args...; kwargs...), oracle_stripe(cst.w, A, args...; kwargs...), cst.w_max)
end

@inline function (ocl::ConstrainedCostOracle)(j::Ti, j′::Ti, k...)
    if ocl.w(j, j′, k...) <= ocl.w_max
        return ocl.f(j, j′, k...)
    else
        return typemax(cost_type(ocl.f))
    end
end

bound_stripe(A::SparseMatrixCSC, K, cst::ConstrainedCost) = bound_stripe(A, K, ocl.f)
bound_stripe(A::SparseMatrixCSC, K, ocl::ConstrainedCostOracle) = bound_stripe(A, K, ocl.f)