defmodule Workbooks.Reclaim.PearTest do
  @moduledoc """
  RECLAIM (PEAR): durable proof that a real PEAR package (Archive_Tar) + its PEAR
  base-class dependency are fetched over the brokered `http` command, staged on the PHP
  include_path, and EXECUTED under the real PHP 8.2.6 wasm32-wasi runtime — creating and
  listing a tar archive.

  `pear install X` is, for pure-PHP packages, exactly:
    (1) FETCH+RESOLVE  — brokered `http` command GETs each package's .php sources
                         (Archive/Tar.php + its `require_once 'PEAR.php'` base class);
    (2) PLACE          — write the resolved files into a host dir mounted into the guest
                         and add it to PHP's include_path;
    (3) RUN            — the `php` command (php-cgi 8.2.6 wasm, VMware WLR) executes a
                         script that uses Archive_Tar.

  NOT reproduced (and not claimed): the `pear` CLI itself, native PECL/phpize C-extension
  builds, or dynamic .so loading. Only the pure-PHP fetch+stage+run install reduction.
  """
  use ExUnit.Case, async: false
  alias Workbooks.CommandRegistry

  @tar_php "https://raw.githubusercontent.com/pear/Archive_Tar/master/Archive/Tar.php"
  @pear_php "https://raw.githubusercontent.com/pear/pear-core/master/PEAR.php"

  setup_all do
    if "python" not in CommandRegistry.list(), do: Workbooks.Pallet.seed_one("python")
    if "php" not in CommandRegistry.list(), do: Workbooks.Pallet.seed_one("php")
    Workbooks.BrokeredTools.register_all()
    :ok
  end

  defp fetch!(url) do
    {:ok, body, 0} = CommandRegistry.run_status("http", "", [url])
    refute body =~ "404: Not Found", "fetch failed for #{url}"
    assert byte_size(body) > 1000, "suspiciously small body for #{url}"
    body
  end

  @tag :netdeps
  @tag :build
  @tag timeout: 300_000
  test "fetch Archive_Tar + PEAR over the http broker, stage on include_path, run under PHP wasm" do
    # (1) FETCH+RESOLVE — the two pure-PHP sources of the package's dep graph
    tar_src = fetch!(@tar_php)
    pear_src = fetch!(@pear_php)
    assert tar_src =~ "class Archive_Tar"
    assert pear_src =~ "class PEAR"

    # (2) PLACE — a host dir mounted into the guest; PEAR layout: PEAR.php at root, Archive/Tar.php under Archive/
    root = Path.join(System.tmp_dir!(), "pear_inc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "Archive"))
    File.write!(Path.join(root, "PEAR.php"), pear_src)
    File.write!(Path.join([root, "Archive", "Tar.php"]), tar_src)

    # the PHP driver: set include_path to our staged dir, require Archive/Tar.php, build a
    # tar from in-memory data, then re-open it and LIST its entries — proving the package runs.
    script = ~S"""
    <?php
    set_include_path('/p');
    require_once 'Archive/Tar.php';
    if (!class_exists('Archive_Tar')) { fwrite(STDERR, "NO CLASS\n"); exit(2); }

    $tarfile = '/p/out.tar';
    $tar = new Archive_Tar($tarfile);
    $ok = $tar->addString('hello.txt', "hello from PEAR Archive_Tar\n");
    $ok2 = $tar->addString('dir/world.txt', "second entry\n");
    if (!$ok || !$ok2) { fwrite(STDERR, "ADD FAILED\n"); exit(3); }

    // re-open and list
    $t2 = new Archive_Tar($tarfile);
    $list = $t2->listContent();
    echo "ENTRIES " . count($list) . "\n";
    foreach ($list as $e) { echo "FILE " . $e['filename'] . " SIZE " . $e['size'] . "\n"; }
    echo "TARBYTES " . filesize($tarfile) . "\n";
    echo "PEAR_OK " . (class_exists('PEAR') ? "yes" : "no") . "\n";
    """

    File.write!(Path.join(root, "script.php"), script)

    # (3) RUN — php-cgi wasm. -q quiets CGI headers; -f runs the file. Mount our staged dir at /p.
    {:ok, out, status} =
      CommandRegistry.run_status("php", "", ["-q", "-f", "/p/script.php"], ["#{root}::/p"])

    assert status == 0, "php exited #{status}:\n#{out}"

    # the package actually ran: PEAR base class loaded, Archive_Tar built + listed a real tar
    assert out =~ "PEAR_OK yes", "PEAR base class did not load:\n#{out}"
    assert out =~ "ENTRIES 2", "Archive_Tar did not list the two entries:\n#{out}"
    assert out =~ "FILE hello.txt", "missing first entry:\n#{out}"
    assert out =~ "FILE dir/world.txt", "missing second entry:\n#{out}"
    assert out =~ ~r/TARBYTES \d+/, "no real tar bytes written:\n#{out}"
  end
end
