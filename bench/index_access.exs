defmodule Bench.IndexAccess do
  def run do
    size = env_int("BENCH_SIZE", 250_000)
    runs_best = env_int("BENCH_RUNS_BEST", 20_000)
    runs_worst = env_int("BENCH_RUNS_WORST", 50)
    bucket_size = Discord.SortedSet.default_bucket_size()

    IO.puts(
      "index access bench (size=#{size}, runs_best=#{runs_best}, runs_worst=#{runs_worst}, bucket_size=#{bucket_size})"
    )

    list = Enum.to_list(1..size)
    set = Discord.SortedSet.from_proper_enumerable(list, bucket_size)

    ordered_set = :gb_sets.from_list(list)

    best_index = 0
    worst_index = size - 1

    report_case("best", best_index, list, ordered_set, set, runs_best)
    report_case("worst", worst_index, list, ordered_set, set, runs_worst)
  end

  defp report_case(label, index, list, ordered_set, set, runs) do
    warmup = fn -> at_list(list, index) end
    warmup.()

    list_us = avg_us(fn -> at_list(list, index) end, runs)

    warmup = fn -> at_ordered_set(ordered_set, index) end
    warmup.()

    ordered_us = avg_us(fn -> at_ordered_set(ordered_set, index) end, runs)

    warmup = fn -> Discord.SortedSet.at(set, index) end
    warmup.()

    sorted_set_us = avg_us(fn -> Discord.SortedSet.at(set, index) end, runs)

    IO.puts("#{label} (index=#{index})")
    IO.puts("  Sorted List: #{format_us(list_us)}")
    IO.puts("  OrderedSet:  #{format_us(ordered_us)}")
    IO.puts("  SortedSet:   #{format_us(sorted_set_us)}")
  end

  defp avg_us(fun, runs) do
    start = System.monotonic_time(:nanosecond)
    for _ <- 1..runs, do: fun.()
    finish = System.monotonic_time(:nanosecond)
    (finish - start) / runs / 1000
  end

  defp at_list(list, index) do
    Enum.at(list, index)
  end

  defp at_ordered_set(ordered_set, index) do
    iterator = :gb_sets.iterator(ordered_set)

    case ordered_set_at_loop(iterator, index) do
      :none -> nil
      {value, _next} -> value
    end
  end

  defp ordered_set_at_loop(iterator, 0) do
    :gb_sets.next(iterator)
  end

  defp ordered_set_at_loop(iterator, index) do
    case :gb_sets.next(iterator) do
      :none -> :none
      {_value, next} -> ordered_set_at_loop(next, index - 1)
    end
  end

  defp env_int(name, fallback) do
    case System.get_env(name) do
      nil -> fallback
      value -> String.to_integer(value)
    end
  end

  defp format_us(value) do
    Float.round(value, 2)
    |> then(&"#{&1}us")
  end
end

Bench.IndexAccess.run()
