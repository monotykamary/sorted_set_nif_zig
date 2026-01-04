# Discord.SortedSet (Zig version)

SortedSet is a fast and efficient data structure that provides certain guarantees and
functionality. The core data structure and algorithms are implemented in a Native Implemented
Function in the Zig Programming Language using a small custom NIF wrapper.

## Installation

Add SortedSet to your dependencies and then install with `mix do deps.get, deps.compile`

```elixir
def deps do
  [
    {:sorted_set_nif, git: "git@github.com:monotykamary/sorted_set_nif_zig.git", branch: "main"}
  ]
end
```

## Implementation Details

Internally the Elixir terms stored in the SortedSet are converted to Zig equivalents and
stored in a vector of vectors. The structure is similar to a skip-list; almost every operation
on the SortedSet will perform a linear scan through the buckets to find the bucket that owns the
term, then a binary search is done within the bucket to complete the operation.

Why not just a Vector of Terms?  This approach was explored but when the Vector needs to grow
beyond it's capacity, copying Terms over to the new larger Vector proved to be a performance
bottle neck.  Using a Vector of Vectors, the Bucket pointers can be quickly copied when
additional capacity is required.

This strategy provides a reasonable trade off between performance and implementation complexity.

When using a SortedSet, the caller can tune bucket sizes to their use case.  A default bucket
size of 500 was chosen as it provides good performance for most use cases.  See `new/2` for
details on how to provide custom tuning details.

## Guarantees

1. Terms in the SortedSet will be sorted based on the Elixir sorting rules.
2. SortedSet is a Set, any item can appear 0 or 1 times in the Set.

## Functionality

There is some special functionality that SortedSet provides beyond sorted and uniqueness
guarantees.

1. SortedSet has a defined ordering, unlike a pure mathematical set.
2. SortedSet can report the index of adding and removing items from the Set due to it's defined
    ordering property.
3. SortedSet can provide random access of items and slices due to it's defined ordering
    property.

## Caveats

1. Due to SortedSet's implementation, some operations that are constant time in sets have
    different performance characteristic in SortedSet, these are noted on the operations.
2. SortedSets do not support some types of Elixir Terms, namely `reference`, `pid`, `port`,
    `function`, and `float`.  Attempting to store any of these types (or an allowed composite
    type containing one of the disallowed types) will result in an error, namely,
    `{:error, :unsupported_type}`

## Documentation

Documentation is [hosted on hexdocs](https://hexdocs.pm/sorted_set_nif).

For a local copy of the documentation, the `mix.exs` file is already set up for  generating
documentation, simply run the following commands to generate the documentation from source.

```bash
mix deps.get
mix docs
```

## Running the Tests

There are two test suites available in this library, an ExUnit test suite that tests the
correctness of the implementation from a black box point of view.  These tests can be run by
running `mix test` in the root of the library.

The Zig code also contains tests; these can be run by running
`zig test native/sorted_set_nif/src/sorted_set.zig`.

## Running the Benchmarks

Before running any benchmarks it's important to remember that during development the NIF will be
built unoptimized.  Make sure to rebuild an optimized version of the NIF before running the
benchmarks.

There are benchmarks available in the `bench` folder, these are written with
[Benchee](https://github.com/PragTob/benchee) and can be run with the following command.

```bash
OPTIMIZE_NIF=true mix run bench/{benchmark}.exs
```

Adding the `OPTIMIZE_NIF=true` will force the benchmark to run against the fully optimized NIF.

Allocator selection (default is BEAM allocator):

```bash
USE_BEAM_ALLOCATOR=1 OPTIMIZE_NIF=true make -B
```

Switch to the system allocator for NIF storage:

```bash
USE_BEAM_ALLOCATOR=0 OPTIMIZE_NIF=true make -B
```

## Benchmark Results

Latency (index access, 1,000,000 items, best = index 0, worst = index 999,999; numbers in μs):

| Case | Sorted List | OrderedSet | SortedSet (Zig+BEAM) | SortedSet (Zig+SYS) | SortedSet (Rust) |
| --- | --- | --- | --- | --- | --- |
| Best | 0.02 | 0.05 | 0.70 | 0.64 | 0.70 |
| Worst | 1452.92 | 7630.11 | 0.70 | 0.76 | 1.09 |

Sorted List and OrderedSet values are BEAM-only baselines from the Zig+BEAM run.

IPS (1000 adds, average of 5 runs):

| Size | Zig+BEAM | Zig+SYS | Rust |
| --- | --- | --- | --- |
| 5,000 | 1169.86 | 1196.46 | 1300.05 |
| 50,000 | 1408.85 | 1443.83 | 1366.12 |
| 250,000 | 1250.31 | 1329.43 | 1200.48 |
| 500,000 | 1265.50 | 1179.52 | 1076.66 |
| 750,000 | 1074.34 | 1178.41 | 1048.22 |
| 1,000,000 | 1135.85 | 1135.85 | 1002.00 |

## Basic Usage

SortedSet lives in the `Discord` namespace to prevent symbol collision, it can be used directly

```elixir
defmodule ExampleModule do
  def get_example_sorted_set() do
    Discord.SortedSet.new()
    |> Discord.SortedSet.add(1)
    |> Discord.SortedSet.add(:atom),
    |> Discord.SortedSet.add("hi there!")
  end
end
```

You can always add an `alias` to make this code less verbose

```elixir
defmodule ExampleModule do
  alias Discord.SortedSet
  
  def get_example_sorted_set() do
    SortedSet.new()
    |> SortedSet.add(1)
    |> SortedSet.add(:atom),
    |> SortedSet.add("hi there!")
  end
end
```

Full API Documentation is available, there is also a full test suite with examples of how the
library can be used.
