# Runs the body gate and its controls; see docs/body.md.
#   GODOT=<double editor> ANNY_FOLLOW=<dir> MUJOCO_ELF=<file> ANNY_GLB=<file> CLIPS=<dir> elixir tools/body.exs
defmodule Body do
  @controls ~w(swap axes flip)

  def main do
    env = for k <- ~w(GODOT ANNY_FOLLOW MUJOCO_ELF ANNY_GLB CLIPS), do: System.get_env(k) || fail("set #{k}")
    [godot, course, elf, glb, clips] = env
    here = File.cwd!()
    base = ["--headless", "--path", course, "-s", Path.join(here, "tests/body_gate.gd"), "--", here, elf, glb, clips]
    clean = run(godot, base)
    IO.puts(ledger(clean))
    unless clean =~ ~r/^RESULT: PASS$/m, do: fail("the run without a control did not pass: #{result(clean)}")
    [_, max] = Regex.run(~r/err_max_mm=([0-9.]+)/, clean)

    bad =
      for c <- @controls do
        out = run(godot, base ++ ["--control=#{c}", "--line=#{max}"])
        IO.puts("#{c}: #{ledger(out)}\n#{c}: #{result(out)}")
        not (out =~ ~r/^RESULT: FAIL/m) or out =~ ~r/^RESULT: (PASS|ERROR)/m
      end

    if Enum.any?(bad), do: fail("a control was not caught")
    IO.puts("RESULT: PASS")
  end

  defp run(godot, args) do
    {out, _} = System.cmd(godot, args, stderr_to_stdout: true)
    out
  end

  defp ledger(out), do: Enum.find(String.split(out, "\n"), "no LEDGER line", &String.starts_with?(&1, "LEDGER"))
  defp result(out), do: Enum.find(String.split(out, "\n"), "no RESULT line", &String.starts_with?(&1, "RESULT"))

  defp fail(msg) do
    IO.puts("RESULT: FAIL " <> msg)
    System.halt(1)
  end
end

Body.main()
