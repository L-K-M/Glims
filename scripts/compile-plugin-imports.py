"""Run with the bundled Python after relinking and signing its libraries."""
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path


def main(contents):
    runtime = Path(sys.base_prefix).resolve()
    if runtime.parent != contents / "lib/Python.framework/Versions":
        raise RuntimeError("Plug-in imports must be compiled by the bundled Python")

    # Load the binding used by Python plug-ins during their native query.
    # Freeze the resulting source set before importing the bytecode compiler.
    import gi
    gi.require_version("Gimp", "3.0")
    from gi.repository import Gimp
    sources = {Path(loader.path).resolve() for module in tuple(sys.modules.values())
               if isinstance(loader := getattr(module, "__loader__", None), SourceFileLoader)}

    import py_compile
    for source in sorted(sources):
        if source.is_relative_to(runtime):
            py_compile.compile(str(source), dfile=str(source.relative_to(contents)), doraise=True,
                               invalidation_mode=py_compile.PycInvalidationMode.CHECKED_HASH)


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
