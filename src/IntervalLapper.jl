module IntervalLapper

export Interval, overlap, intersect
export Lapper, find, seek, lower_bound, merge_overlaps!, coverage, union_and_intersect

"""
Represents an interval of (start, stop] with a label val.
"""
struct Interval{T}
	start::Int
	stop::Int
	val::T
end

"""
Check if two intervals overlap.

# Example
```jldoctest
julia> overlap(Interval(0, 10, "cats"), Interaval(5, 15, "Dogs"))
true
```
"""
function overlap(a::Interval, b::Interval)
	a.start < b.stop && a.stop > b.start
end

function overlap(a::Interval, start::Int, stop::Int)
	a.start < stop && a.stop > start
end

"""
Determine the number of positions shared by two intervals

# Example
```jldoctest
julia> intersect(Interval(0, 10, "cats"), Interaval(5, 15, "Dogs"))
5
```
"""
function intersectlen(a::Interval, b::Interval)
	diff = min(a.stop, b.stop) - max(a.start, b.start)
	diff >= 0 ? diff : 0
end

"""
Primary object of the library. The intervals can be used for iterating / pulling values out of the tree
"""
mutable struct Lapper{T}
	intervals::Vector{Interval{T}}
	max_len::Int
	cursor::Int
	cov::Union{Nothing, Int}
	overlaps_merged::Bool
end


function Lapper(intervals::Vector{Interval{T}}) where T
	sort!(intervals, by = x -> (x.start))
	max_len = 0
	for interval in intervals
		iv_len = interval.stop - interval.start # add an check for intervals where this could be negative?
		if iv_len > max_len
			max_len = iv_len
		end
	end
	return Lapper(intervals, max_len, 0, nothing, false)
end

function lower_bound(start::Int, intervals::Vector{Interval{T}}) where T
	size = length(intervals) + 1
	low = 1

	@inbounds while size > 1
		half = div(size, 2)
		other_half = size - half
		probe = low + half
		other_low = low + other_half
		v = intervals[probe]
		size = half
		low = v.start < start ? other_low : low
	end

	low
end

"""
Merge any intervals that overlap with eachother within the Lapper. This is an easy
way to speed up queries.
"""
function merge_overlaps!(lapper::Lapper{T}) where T
	if length(lapper.intervals) <= 1
		lapper.overlaps_merged = true
		return
	elseif lapper.overlaps_merged
		return
	end

	stack = Vector{Interval{T}}()
	first = lapper.intervals[1]
	push!(stack, first)
	for interval in lapper.intervals[2:end]
		top = pop!(stack)
		if top.stop < interval.start
			push!(stack, top)
			push!(stack, interval)
		elseif top.stop < interval.stop
			top = Interval{T}(top.start, interval.stop, interval.val)
			push!(stack, top)
		else
			# they were equal
			push!(stack, top)
		end
	end
	lapper.overlaps_merged = true
	lapper.intervals = stack
end

"""
Calculate the nuber of positions covered by the intervals in Lapper.
"""
function coverage(lapper::Lapper{T}) where T
	moving_start = 0
	moving_stop = 0
	cov = 0

	for interval in lapper.intervals
		if overlap(interval, moving_start, moving_stop)
			moving_start = min(moving_start, interval.start)
			moving_stop = max(moving_stop, interval.stop)
		else
			cov += moving_stop - moving_start
			moving_start = interval.start
			moving_stop = interval.stop
		end
	end
	cov += moving_stop - moving_stop
	cov
end


"""
Find the union and the intersect of two lapper objects.
Union: The set of positions found in both lappers
Intersect: The number of positions where both lappers intersect. Note that a position only
ounts one time, multiple Intervals covering the same position don't add up.
TODO: make this and other funcitons more generic an not depend on T if they don't have to 
"""
function union_and_intersect(self::Lapper{T}, other::Lapper{T}, self_cov::Union{Nothing, Int}=nothing, other_cov::Union{Nothing, Int}=nothing) where T
	cursor = Ref(1)
	if !self.overlaps_merged || !other.overlaps_merged
		intersections = Vector{Interval{Bool}}()
		for self_iv in self.intervals
			for other_iv in seek(other, self_iv.start, self_iv.stop, cursor)
				start = max(self_iv.start, other_iv.start)
				stop = min(self_iv.stop, other_iv.stop)
				push!(intersections, Interval(start, stop, true))
			end
		end
		temp_lapper = Lapper(intersections)
		merge_overlaps!(temp_lapper)
		temp_cov = coverage(temp_lapper)
		other_cov = isnothing(other_cov) ? coverage(other) : other_cov
		self_cov = isnothing(self_cov) ? coverage(self) : self_cov
		union = self_cov + other_cov - temp_cov
		return union, temp_cov
	else
		intersect = 0
		for c1_iv in self.intervals
			for c2_iv in seek(other, c1_iv.start, c1_iv.stop, cursor)
				local_intersect = intersectlen(c1_iv, c2_iv)
				intersect += local_intersect
			end
		end
		other_cov = isnothing(other_cov) ? coverage(other) : other_cov
		self_cov = isnothing(self_cov) ? coverage(self) : self_cov
		union =  self_cov + other_cov - intersect
		return (union, intersect)
	end
end

#=
#
# Find Iterator / Seek Iterator
#
=#

@inline function checked_sub(a::Int, b::Int, or=1)
	maybe = a - b
	maybe >= 1 ? maybe : or
end

struct FindIter{T}
	inner::Lapper{T}
	start::Int
	stop::Int
end

struct SeekIter{T}
	inner::Lapper{T}
	start::Int
	stop::Int
	cursor::Ref{Int}
end

@inline function _find(iter::Union{FindIter, SeekIter}, offset::Ref{Int})
    while offset[] < length(iter.inner.intervals)
	interval = iter.inner.intervals[offset[]]
	offset[] += 1
        if overlap(interval, iter.start, iter.stop)
	    return (interval, offset)
        elseif interval.start >= iter.stop
            break
        end
    end
    nothing
end

find(lapper::Lapper{T}, start::Int, stop::Int) where T = FindIter(lapper, start, stop)
Base.iterate(iter::FindIter, offset=Ref(lower_bound(checked_sub(iter.start, iter.inner.max_len), iter.inner.intervals))) = _find(iter, offset)
Base.IteratorSize(::FindIter) = Base.SizeUnknown()

function seek(lapper::Lapper{T}, start::Int, stop::Int, cursor::Ref{Int}) where T
	if cursor[] <= 1 || (cursor[] < length(lapper.intervals) && lapper.intervals[cursor[]].start > start)
		cursor[] = lower_bound(checked_sub(start, lapper.max_len), lapper.intervals)
	end
	
	while cursor[] + 1 <= length(lapper.intervals) && lapper.intervals[cursor[] + 1].start < checked_sub(start, lapper.max_len)
		cursor[] += 1
	end
	SeekIter(lapper, start, stop, cursor)
end

Base.iterate(iter::SeekIter, offset=iter.cursor) = _find(iter, offset)
Base.IteratorSize(::SeekIter) = Base.SizeUnknown()

end # module
