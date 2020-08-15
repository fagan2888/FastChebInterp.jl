"""
Fast multidimensional Chebyshev interpolation on a hypercube (Cartesian-product)
domain, using a separable (tensor-product) grid of Chebyshev interpolation points.

For domain upper and lower bounds `lb` and `ub`, and a given `order`
tuple, you would create an interpolator for a function `f` via:
```
using FastChebInterp
x = chebpoints(order, lb, ub) # an array of StaticVector
c = chebinterp(f.(x), lb, ub)
```
and then evaluate the interpolant for a point `y` (a vector)
via `c(y)`.
"""
module FastChebInterp

export chebpoints, chebinterp

using StaticArrays
import FFTW

"""
    ChebInterp

A multidimensional Chebyshev-polynomial interpolation object.
Given a `c::ChebInterp`, you can evaluate it at a point `x`
with `c(x)`, where `x` is a vector (or a scalar if `c` is 1d).
"""
struct ChebInterp{N,T,Td<:Real}
    coefs::Array{T,N} # chebyshev coefficients
    lb::SVector{N,Td} # lower/upper bounds
    ub::SVector{N,Td} #    of the domain
end

function Base.show(io::IO, c::ChebInterp)
    print(io, "Chebyshev order ", map(i->i-1,size(c.coefs)), " interpolator on ",
          '[', c.lb[1], ',', c.ub[1], ']')
    for i = 2:length(c.lb)
        print(io, " × [", c.lb[1], ',', c.ub[1], ']')
    end
end
Base.ndims(c::ChebInterp) = ndims(c.coefs)

chebpoint(i::CartesianIndex{N}, order::NTuple{N,Int}, lb::SVector{N}, ub::SVector{N}) where {N} =
    @. lb + (1 + cos($SVector($Tuple(i)) * π / $SVector(order))) * (ub - lb) * 0.5

chebpoints(order::NTuple{N,Int}, lb::SVector{N}, ub::SVector{N}) where {N} =
    [chebpoint(i,order,lb,ub) for i in CartesianIndices(map(n -> 0:n, order))]

"""
    chebpoints(order, lb, ub)

Return an array of Chebyshev points (as `SVector` values) for
the given `order` (an array or tuple of polynomial degrees),
and hypercube lower-and upper-bound vectors `lb` and `ub`.
If `ub` and `lb` are numbers, returns an array of numbers.

These are the points where you should evaluate a function
in order to create a Chebyshev interpolant with `chebinterp`.

(Note that the number of points along each dimension is `1 +`
the order in that direction.)
"""
function chebpoints(order, lb, ub)
    N = length(order)
    N == length(lb) == length(ub) || throw(DimensionMismatch())
    return chebpoints(NTuple{N,Int}(order), SVector{N}(lb), SVector{N}(ub))
end

chebpoints(order::Integer, lb::Real, ub::Real) =
    first.(chebpoints(order, SVector(lb), SVector(ub)))

# O(n log n) method to compute Chebyshev coefficients
function chebcoefs(vals::AbstractArray{<:Number,N}) where {N}
    coefs = FFTW.r2r(vals, FFTW.REDFT00) # type-I DCT

    # renormalize the result to obtain the conventional
    # Chebyshev-polnomial coefficients
    s = size(coefs)
    coefs ./= prod(map(n -> 2(n-1), s))
    for dim = 1:N
        coefs[CartesianIndices(ntuple(i -> i == dim ? (2:s[i]-1) : (1:s[i]), Val{N}()))] .*= 2
    end

    return coefs
end

function chebcoefs(vals::AbstractArray{<:SVector{K}}) where {K}
    # TODO: in principle we could call FFTW's low-level interface
    # to perform all the transforms simultaneously, rather than
    # transforming each component separately.
    coefs = ntuple(i -> chebcoefs([v[i] for v in vals]), Val{K}())
    return SVector{K}.(coefs...)
end

function chebcoefs(vals::AbstractArray{<:AbstractVector})
    K, K′ = extrema(length, vals)
    K == K′ || throw(ArgumentError("array elements must all be of the same length"))
    return chebcoefs(SVector{K}.(vals))
end

function chebinterp(vals::AbstractArray{<:Any,N}, lb::SVector{N}, ub::SVector{N}) where {N}
    Td = promote_type(eltype(lb), eltype(ub))
    coefs = chebcoefs(vals)
    return ChebInterp{N,eltype(coefs),Td}(coefs, SVector{N,Td}(lb), SVector{N,Td}(ub))
end

"""
    chebinterp(vals, lb, ub)

Given a multidimensional array `vals` of function values (at
points corresponding to the coordinates returned by `chebpoints`),
and arrays `lb` and `ub` of the lower and upper coordinate bounds
of the domain in each direction, returns a Chebyshev interpolation
object (a `ChebInterp`).

This object `c = chebinterp(vals, lb, ub)` can be used to
evaluate the interpolating polynomial at a point `x` via
`c(x)`.

The elements of `vals` can be vectors as well as numbers, in order
to interpolate vector-valued functions (i.e. to interpolate several
functions at once).
"""
chebinterp(vals::AbstractArray{<:Any,N}, lb, ub) where {N} =
    chebinterp(vals, SVector{N}(lb), SVector{N}(ub))

"""
    interpolate(x, c::Array{T,N}, ::Val{dim}, i1, len)

Low-level interpolation function, which performs a
multidimensional Clenshaw recurrence by recursing on
the coefficient (`c`) array dimension `dim` (from `N` to `1`).   The
current dimension (via column-major order) is accessed
by `c[i1 + (i-1)*Δi]`, i.e. `i1` is the starting index and
`Δi = len ÷ size(c,dim)` is the stride.   `len` is the
product of `size(c)[1:dim]`. The interpolation point `x`
should lie within [-1,+1] in each coordinate.
"""
function interpolate(x::SVector{N}, c::Array{<:Any,N}, ::Val{dim}, i1, len) where {N,dim}
    n = size(c,dim)
    @inbounds xd = x[dim]
    if dim == 1
        c₁ = c[i1]
        if n ≤ 2
            n == 1 && return c₁ + xd * zero(c₁)
            return c₁ + xd*c[i1]
        end
        @inbounds bₖ = c[i1+(n-2)] + 2xd*c[i1+(n-1)]
        @inbounds bₖ₊₁ = oftype(bₖ, c[i1+(n-1)])
        for j = n-3:-1:1
            @inbounds bⱼ = c[i1+j] + 2xd*bₖ - bₖ₊₁
            bₖ, bₖ₊₁ = bⱼ, bₖ
        end
        return c₁ + xd*bₖ - bₖ₊₁
    else
        Δi = len ÷ n # column-major stride of current dimension

        # we recurse downward on dim for cache locality,
        # since earlier dimensions are contiguous
        dim′ = Val{dim-1}()

        c₁ = interpolate(x, c, dim′, i1, Δi)
        if n ≤ 2
            n == 1 && return c₁ + xd * zero(c₁)
            c₂ = interpolate(x, c, dim′, i1+Δi, Δi)
            return c₁ + xd*c₂
        end
        cₙ₋₁ = interpolate(x, c, dim′, i1+(n-2)*Δi, Δi)
        cₙ = interpolate(x, c, dim′, i1+(n-1)*Δi, Δi)
        bₖ = cₙ₋₁ + 2xd*cₙ
        bₖ₊₁ = oftype(bₖ, cₙ)
        for j = n-3:-1:1
            cⱼ = interpolate(x, c, dim′, i1+j*Δi, Δi)
            bⱼ = cⱼ + 2xd*bₖ - bₖ₊₁
            bₖ, bₖ₊₁ = bⱼ, bₖ
        end
        return c₁ + xd*bₖ - bₖ₊₁
    end
end

"""
    (interp::ChebInterp)(x)

Evaluate the Chebyshev polynomial given by `interp` at the point `x`.
"""
function (interp::ChebInterp{N})(x::SVector{N,<:Real}) where {N}
    x0 = @. (x - interp.lb) * 2 / (interp.ub - interp.lb) - 1
    all(abs.(x0) .≤ 1) || throw(ArgumentError("$x not in domain"))
    return interpolate(x0, interp.coefs, Val{N}(), 1, length(interp.coefs))
end

(interp::ChebInterp{N})(x::AbstractVector{<:Real}) where {N} = interp(SVector{N}(x))
(interp::ChebInterp{1})(x::Real) = interp(SVector{1}(x))

end # module
