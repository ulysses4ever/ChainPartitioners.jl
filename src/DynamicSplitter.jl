abstract type AbstractDynamicSplitter{F} end

struct DynamicBottleneckSplitter{F} <: AbstractDynamicSplitter{F}
    f::F
end

@inline _dynamic_splitter_combine(::DynamicBottleneckSplitter) = max

struct DynamicTotalSplitter{F} <: AbstractDynamicSplitter{F}
    f::F
end

@inline _dynamic_splitter_combine(::DynamicTotalSplitter) = +

function partition_stripe(A::SparseMatrixCSC{Tv, Ti}, K, method::AbstractDynamicSplitter, args...) where {Tv, Ti}
    @inbounds begin
        (m, n) = size(A)

        f = oracle_stripe(StepHint(), method.f, A, args...; b = 1)
        g = _dynamic_splitter_combine(method)

        @stabilize Tv Ti A m n K f g begin
            ptr = zeros(Ti, K, n + 1)
            cst = fill(typemax(cost_type(f)), K, n + 1)

            for j′ = 1:n + 1
                cst[1, j′] = f(1, j′, 1)
                ptr[1, j′] = 1
                for j = 1:j′
                    f(j, j′, 1)
                    for k = 2:K
                        c_lo = Step(f, Same(), Same(), Jump())(j, j′, k)
                        if g(cst[k - 1, j], c_lo) <= cst[k, j′]
                            cst[k, j′] = g(cst[k - 1, j], c_lo)
                            ptr[k, j′] = j
                        end
                    end
                end
            end
            return unravel_splits(K, n, ptr)
        end
    end
end

function unravel_splits(K, n, ptr)
    @inbounds begin
        spl = zeros(eltype(ptr), K + 1)
        spl[end] = n + 1
        for k = K:-1:1
            spl[k] = ptr[k, spl[k + 1]]
        end

        return SplitPartition(K, spl)
    end
end

struct WindowConstrainedMatrix{Tv, Ti} <: AbstractMatrix{Tv}
    z::Tv
    m::Int
    n::Int
    idx_lo::Vector{Ti}
    idx_hi::Vector{Ti}
    pos::Vector{Ti}
    val::Vector{Tv}
end

function WindowConstrainedMatrix{Tv, Ti}(z, m, n, idx_lo::Vector{Ti}, idx_hi::Vector{Ti}) where {Ti, Tv}
    @inbounds begin
        pos = undefs(Ti, n + 1)
        pos[1] = 1
        for j = 1:n
            pos[j + 1] = pos[j] + idx_hi[j] - idx_lo[j] + 1
        end
        WindowConstrainedMatrix{Tv, Ti}(z, m, n, idx_lo, idx_hi, pos)
    end
end

function WindowConstrainedMatrix{Tv, Ti}(z, m, n, idx_lo::Vector{Ti}, idx_hi::Vector{Ti}, pos::Vector{Ti}) where {Ti, Tv}
    return WindowConstrainedMatrix{Tv, Ti}(z, m, n, idx_lo, idx_hi, pos, undefs(Tv, pos[end]))
end

Base.size(A::WindowConstrainedMatrix) = (A.m, A.n)
@propagate_inbounds function Base.getindex(A::WindowConstrainedMatrix{Tv}, i, j) where {Tv}
    @boundscheck checkbounds(A, i, j)
    if A.idx_lo[j] <= i <= A.idx_hi[j]
        return A.val[A.pos[j] + i - A.idx_lo[j]]
    else
        return A.z
    end
end
@propagate_inbounds function Base.setindex!(A::WindowConstrainedMatrix{Tv}, v, i, j) where {Tv}
    @boundscheck checkbounds(A, i, j)
    if A.idx_lo[j] <= i <= A.idx_hi[j]
        return A.val[A.pos[j] + i - A.idx_lo[j]] = v
    else
        return A.z
    end
end

function column_constraints(A::SparseMatrixCSC{Tv, Ti}, K, w, w_max) where {Tv, Ti}
    @inbounds begin
        (m, n) = size(A)

        j′_lo = undefs(Ti, K)
        j′ = n + 1
        for k = K:-1:1
            j′_lo[k] = j′
            j = j′
            while j - 1 >= 1 && w(j - 1, j′, k) <= w_max
                j -= 1
            end
            j′ = j
        end

        j′_hi = undefs(Ti, K)
        j = 1
        for k = 1:K
            j′ = j
            while j′ + 1 <= n + 1 && w(j, j′ + 1, k) <= w_max
                j′ += 1
            end
            j′_hi[k] = j′
            j = j′
        end

        return (j′_lo, j′_hi)
    end
end
 
function part_constraints(A::SparseMatrixCSC{Tv, Ti}, K, w, w_max) where {Tv, Ti}
    @inbounds begin
        (m, n) = size(A)

        k_hi = zeros(Ti, n + 1)
        j′ = n + 1
        k_hi[end] = K
        for k = K:-1:1
            j = j′
            while j - 1 >= 1 && w(j - 1, j′, k) <= w_max
                j -= 1
                k_hi[j] = k - 1
            end
            j′ = j
        end

        k_lo = zeros(Ti, n + 1)
        j = 1
        k_lo[1] = 1
        for k = 1:K
            j′ = j
            while j′ + 1 <= n + 1 && w(j, j′ + 1, k) <= w_max
                j′ += 1
                k_lo[j′] = k
            end
            j = j′
        end

        return (k_lo, k_hi)
    end
end

function partition_stripe(A::SparseMatrixCSC{Tv, Ti}, K, method::AbstractDynamicSplitter{<:ConstrainedCost}, args...) where {Tv, Ti}
    @inbounds begin
        (m, n) = size(A)

        f = oracle_stripe(StepHint(), method.f, A, args...; b = 1)
        f′ = f.f
        w = f.w
        w_max = method.f.w_max
        g = _dynamic_splitter_combine(method)

        @stabilize Tv Ti A K m n f f′ w w_max g begin
            #=
            (j′_lo, j′_hi) = column_constraints(A, K, w, w_max)

            if j′_hi[K] < n + 1
                spl = ones(Ti, K + 1)
                spl[end] = n + 1
                #TODO throw(ArgumentError("infeasible"))
                return SplitPartition(K, spl)
            end

            ptr = WindowConstrainedMatrix{Ti, Ti}(zero(Ti), n + 1, K, j′_lo, j′_hi)
            cst = WindowConstrainedMatrix{extend(cost_type(f)), Ti}(infinity(cost_type(f)), n + 1, K, j′_lo, j′_hi, ptr.pos)

            for j′ = j′_lo[1] : j′_hi[1]
                cst[j′, 1] = f(1, j′, 1)
                ptr[j′, 1] = 1
            end

            for k = 2:K
                j₀ = j′_lo[k - 1]
                for j′ = j′_lo[k] : j′_hi[k]
                    while w(j₀, j′, k) > w_max #TODO can this run over the end?
                        j₀ += 1
                    end
                    cst[j′, k] = g(cst[j₀, k - 1], f(j₀, j′, k))
                    ptr[j′, k] = j₀
                    for j = j₀ + 1 : min(j′, j′_hi[k - 1])
                        c′ = g(cst[j, k - 1], Step(f, Next(), Same(), Same())(j, j′, k))
                        if c′ <= cst[j′, k]
                            cst[j′, k] = c′ 
                            ptr[j′, k] = j
                        end
                    end
                end
            end

            return unravel_splits(K, n, PermutedDimsArray(ptr, (2, 1)))
            =#

            (k_lo, k_hi) = part_constraints(A, K, w, w_max)

            if k_lo[n + 1] == 0
                spl = ones(Ti, K + 1)
                spl[end] = n + 1
                #TODO throw(ArgumentError("infeasible"))
                return SplitPartition(K, spl)
            end

            ptr = WindowConstrainedMatrix{Ti, Ti}(zero(Ti), K, n + 1, k_lo, k_hi)
            cst = WindowConstrainedMatrix{extend(cost_type(f)), Ti}(infinity(cost_type(f)), K, n + 1, k_lo, k_hi, ptr.pos)
            fill!(cst.val, infinity(cost_type(f)))

            j₀ = 1
            for j′ = 1:n + 1
                if k_lo[j′] == 1
                    cst[k_lo[j′], j′] = f(1, j′, k_lo[j′])
                    ptr[k_lo[j′], j′] = 1
                end
                while k_lo[j₀] < k_lo[j′] - 1
                    j₀ += 1
                end
                f′(j₀, j′, k_lo[j₀])
                for k = k_lo[j₀] + 1:k_hi[j′]
                    c_lo = extend(Step(f′, Same(), Same(), Next())(j₀, j′, k))
                    if w(j₀, j′, k) <= w_max && g(cst[k - 1, j₀], c_lo) <= cst[k, j′]
                        cst[k, j′] = g(cst[k - 1, j₀], c_lo)
                        ptr[k, j′] = j₀
                    end
                end
                for j = j₀ + 1:j′
                    Step(f′, Next(), Same(), Jump())(j, j′, k_lo[j])
                    for k = k_lo[j] + 1:k_hi[j′]
                        c_lo = extend(Step(f′, Same(), Same(), Next())(j, j′, k))
                        if w(j, j′, k) <= w_max && g(cst[k - 1, j], c_lo) <= cst[k, j′]
                            cst[k, j′] = g(cst[k - 1, j], c_lo)
                            ptr[k, j′] = j
                        end
                    end
                end
            end
            return unravel_splits(K, n, ptr)
        end
    end
end