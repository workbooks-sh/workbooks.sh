# ---- 1) prove from_asm: hand-built BEAM assembly -> load -> run ----
asm = """
{module, wbspike}.
{exports, [{add,2}]}.
{attributes, []}.
{labels, 3}.
{function, add, 2, 2}.
  {label,1}.
    {func_info,{atom,wbspike},{atom,add},2}.
  {label,2}.
    {gc_bif,'+',{f,0},2,[{x,0},{x,1}],{x,0}}.
    return.
"""
File.write!("/tmp/wbspike.S", asm)
{:ok, mod, bin} = :compile.file(~c"/tmp/wbspike.S", [:from_asm, :binary])
{:module, ^mod} = :code.load_binary(mod, ~c"/tmp/wbspike.S", bin)
IO.puts("from_asm add(3,4) = #{apply(mod, :add, [3,4])}  (native via BeamAsm? flavor=#{:erlang.system_info(:emu_flavor)})")

# ---- 2) compile-time: from_asm vs abstract-forms on a scaled straight-line function ----
n = 800
# (a) abstract forms: f(X) -> X+1+1+...+1  (n adds)
ln = 1
body = Enum.reduce(1..n, {:var, ln, :X}, fn _, acc -> {:op, ln, :+, acc, {:integer, ln, 1}} end)
forms = [
  {:attribute, ln, :module, :wbforms},
  {:attribute, ln, :export, [{:f, 1}]},
  {:function, ln, :f, 1, [{:clause, ln, [{:var, ln, :X}], [], [body]}]}
]
{tf, {:ok, :wbforms, _}} = :timer.tc(fn -> :compile.forms(forms, [:return_errors, :binary]) end)

# (b) from_asm: the SAME computation as n sequential gc_bif '+' into x0
asm_lines = Enum.map_join(1..n, "\n", fn _ -> "    {gc_bif,'+',{f,0},1,[{x,0},{integer,1}],{x,0}}." end)
asm2 = """
{module, wbforms2}.
{exports, [{f,1}]}.
{attributes, []}.
{labels, 3}.
{function, f, 1, 2}.
  {label,1}.
    {func_info,{atom,wbforms2},{atom,f},1}.
  {label,2}.
#{asm_lines}
    return.
"""
File.write!("/tmp/wbforms2.S", asm2)
{ta, {:ok, :wbforms2, _}} = :timer.tc(fn -> :compile.file(~c"/tmp/wbforms2.S", [:from_asm, :binary]) end)

IO.puts("compile #{n}-op fn:  abstract_forms=#{Float.round(tf/1000,1)}ms   from_asm=#{Float.round(ta/1000,1)}ms   speedup=#{Float.round(tf/ta,2)}x")
