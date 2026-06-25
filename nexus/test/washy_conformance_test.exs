defmodule Nexus.WashyConformanceTest do
  @moduledoc """
  The Wave-3 forcing function (wb-vlxn): run REAL, unmodified npm packages on Washy and assert their
  behavior. This is the empirical gate that turns "we think it works" into "package X passes" — and it
  earns its keep: the very first run (lodash) surfaced the IEEE-754 float gap (wb-8mdz.3, now fixed).

  Fixtures are the real single-file UMD builds, vendored under test/conformance/. Each loads through the
  Sandbox interp lane exactly as a guest would, then a battery of operations is checked against expected
  output. A package's driver writes `PASS <name>` / `FAIL <name>` lines; the test asserts zero FAILs.
  Add packages as they're brought up; every failure → a precise bd issue under the Node epic.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.Sandbox

  @qjs "compilers/js/qjs-run.wasm"
  @dir "test/conformance"

  # run a vendored package fixture + a driver that emits PASS/FAIL lines; assert no FAILs.
  defp conform(fixture, driver) do
    qjs = @qjs
    path = Path.join(@dir, fixture)

    if File.exists?(qjs) and File.exists?(path) do
      js = File.read!(path) <> "\n;\n" <> driver
      assert {:ok, out} = Sandbox.run_command({:interp, qjs, js}, "", fuel: 2_000_000_000_000, timeout_ms: 120_000)
      lines = String.split(out, "\n", trim: true)
      fails = Enum.filter(lines, &String.starts_with?(&1, "FAIL"))
      assert fails == [], "#{fixture} conformance failures: #{inspect(fails)}\nfull: #{out}"
      length(lines)
    else
      IO.puts("\n[skip] missing qjs-run.wasm or fixture #{fixture}")
      :skip
    end
  end

  @emit "Javy.IO.writeSync(1,new TextEncoder().encode(out.join('\\n')));"

  test "lodash 4.17.21 — array/object/string utilities" do
    n = conform("lodash-4.17.21.js", """
    var _ = module.exports;var out=[];
    function t(n,g,w){out.push((JSON.stringify(g)===JSON.stringify(w)?'PASS ':'FAIL ')+n);}
    t('VERSION',_.VERSION,'4.17.21');
    t('chunk',_.chunk([1,2,3,4],2),[[1,2],[3,4]]);
    t('map',_.map([1,2,3],function(x){return x*2;}),[2,4,6]);
    t('groupBy',_.groupBy([1,2,3,4],function(x){return x%2;}),{0:[2,4],1:[1,3]});
    t('cloneDeep',_.cloneDeep({a:{b:1}}),{a:{b:1}});
    t('get',_.get({a:{b:{c:7}}},'a.b.c'),7);
    t('merge',_.merge({a:1},{b:2}),{a:1,b:2});
    t('camelCase',_.camelCase('foo bar'),'fooBar');
    t('template',_.template('hi <%= n %>')({n:'x'}),'hi x');
    t('uniq',_.uniq([1,1,2,3,3]),[1,2,3]);
    #{@emit}
    """)

    assert n == :skip or n >= 9
  end

  test "dayjs 1.11.10 — date parsing/formatting/math" do
    conform("dayjs-1.11.10.js", """
    var d = module.exports;var out=[];
    function t(n,g,w){out.push((String(g)===String(w)?'PASS ':'FAIL ')+n);}
    t('format',d('2020-03-15').format('YYYY/MM/DD'),'2020/03/15');
    t('add',d('2020-01-01').add(10,'day').format('YYYY-MM-DD'),'2020-01-11');
    t('diff',d('2020-01-11').diff(d('2020-01-01'),'day'),10);
    t('month',d('2020-06-15').month(),5);
    t('day',d('2020-03-15').day(),0);
    t('isBefore',d('2020-01-01').isBefore(d('2020-02-01')),true);
    t('startOf',d('2020-06-15').startOf('month').format('YYYY-MM-DD'),'2020-06-01');
    #{@emit}
    """)
  end

  test "marked 4.3.0 — markdown → HTML (regex-heavy)" do
    conform("marked-4.3.0.js", """
    var parse = module.exports.parse || module.exports;var out=[];
    function h(s,sub){return s.indexOf(sub)>=0;}
    function t(n,ok){out.push((ok?'PASS ':'FAIL ')+n);}
    t('h1',h(parse('# Hello'),'<h1')&&h(parse('# Hello'),'Hello'));
    t('boldem',h(parse('**b** *e*'),'<strong>')&&h(parse('**b** *e*'),'<em>'));
    t('list',h(parse('- a\\n- b'),'<ul>')&&h(parse('- a\\n- b'),'<li>'));
    t('code',h(parse('`x`'),'<code>'));
    t('link',h(parse('[x](http://y.com)'),'href="http://y.com"'));
    #{@emit}
    """)
  end

  test "bignumber.js 9.1.2 — arbitrary-precision math (stresses int/float paths)" do
    conform("bignumber-9.1.2.js", """
    var B = module.exports;var out=[];
    function t(n,g,w){out.push((String(g)===String(w)?'PASS ':'FAIL ')+n);}
    t('add',new B('0.1').plus('0.2').toString(),'0.3');
    t('mul',new B('123456789').times('987654321').toString(),'121932631112635269');
    t('div',new B('1').dividedBy('3').toFixed(10),'0.3333333333');
    t('pow',new B('2').pow(64).toString(),'18446744073709551616');
    t('sqrt',new B('2').sqrt().toFixed(8),'1.41421356');
    t('mod',new B('17').mod('5').toString(),'2');
    #{@emit}
    """)
  end

  test "picocolors 1.0.0 — terminal colors (exercises process.env/argv + tty)" do
    conform("picocolors-1.0.0.js", """
    var pc = module.exports;var out=[];
    function t(n,ok){out.push((ok?'PASS ':'FAIL ')+n);}
    t('red-fn', typeof pc.red==='function');
    t('no-tty-plain', pc.red('x')==='x');
    t('isColorSupported', typeof pc.isColorSupported==='boolean');
    t('createColors', typeof pc.createColors==='function');
    #{@emit}
    """)
  end
end
