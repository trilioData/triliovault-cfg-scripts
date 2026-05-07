#!/bin/bash

# Bootstrap and exit if KOLLA_BOOTSTRAP variable is set. This catches all cases
# of the KOLLA_BOOTSTRAP variable being set, including empty.

# Python 3.12 removed the 'imp' module; workloadmgr still uses it.
# Create a minimal compatibility shim in a temp dir and prepend to PYTHONPATH.
_setup_imp_shim() {
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/imp.py" << 'IMPEOF'
"""Compatibility shim: 'imp' module was removed in Python 3.12."""
import importlib.util
import sys
import types

PY_SOURCE = 1
PY_COMPILED = 2
C_EXTENSION = 3

def load_source(name, pathname, file=None):
    spec = importlib.util.spec_from_file_location(name, pathname)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

def load_module(name, file, pathname, description):
    return load_source(name, pathname)

def find_module(name, path=None):
    spec = importlib.util.find_spec(name)
    if spec is None:
        raise ImportError("No module named {!r}".format(name))
    return None, spec.origin, ('', '', PY_SOURCE)

def new_module(name):
    return types.ModuleType(name)

def acquire_lock():
    pass

def release_lock():
    pass
IMPEOF
    echo "$tmpdir"
}

if [[ "${!KOLLA_BOOTSTRAP[@]}" ]]; then
    _IMP_SHIM_DIR=$(_setup_imp_shim)
    PYTHONPATH="$_IMP_SHIM_DIR:$PYTHONPATH" alembic --config /etc/triliovault-wlm/triliovault-wlm.conf upgrade head
    _rc=$?
    rm -rf "$_IMP_SHIM_DIR"
    exit $_rc
fi

if [[ "${!KOLLA_UPGRADE[@]}" ]]; then
    _IMP_SHIM_DIR=$(_setup_imp_shim)
    PYTHONPATH="$_IMP_SHIM_DIR:$PYTHONPATH" alembic --config /etc/triliovault-wlm/triliovault-wlm.conf upgrade head
    _rc=$?
    rm -rf "$_IMP_SHIM_DIR"
    exit $_rc
fi
