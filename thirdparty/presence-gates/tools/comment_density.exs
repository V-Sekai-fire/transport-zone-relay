defmodule Density do
  @limit 0.03

  def main(files) do
    rows = Enum.map(files, &row/1)
    for {f, c, n} <- rows, do: IO.puts("#{Float.round(100 * c / max(n, 1), 1)}%\t#{c}/#{n}\t#{f}")
    over = for {f, c, n} <- rows, c / max(n, 1) > @limit, do: f
    IO.puts("RESULT: #{if over == [], do: "PASS", else: "FAIL " <> Enum.join(over, " ")}")
    System.halt(if over == [], do: 0, else: 1)
  end

  defp row(file) do
    lines = file |> File.read!() |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    marks = if Path.extname(file) in ~w(.cpp .h .c), do: ["//", "/*", "*"], else: ["#"]
    {file, Enum.count(lines, fn l -> Enum.any?(marks, &String.starts_with?(l, &1)) end), length(lines)}
  end
end

Density.main(System.argv())
