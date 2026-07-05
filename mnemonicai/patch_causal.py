"""Pure-PyTorch fallback for the causal-conv1d CUDA extension.

Import this module BEFORE anything that imports `causal_conv1d`
(mamba_ssm, transformers Mamba paths, fla's cuda backend, ...).
If the real compiled package is available it is left untouched;
otherwise a mathematically equivalent shim is injected into sys.modules.
"""
from __future__ import annotations

import sys
from importlib.machinery import ModuleSpec
from types import ModuleType

try:
    import torch
    import torch.nn.functional as F
    _HAS_TORCH = True
except ImportError:
    _HAS_TORCH = False  # inference-proxy deployments don't need torch


def causal_conv1d_fallback(
    x, weight, bias=None, seq_idx=None, initial_states=None,
    return_final_states=False, final_states_out=None, activation=None,
):
    """Reference-equivalent causal depthwise conv.

    x: (batch, dim, seqlen)   weight: (dim, width)
    initial_states: (batch, dim, width-1) or None
    """
    if activation not in (None, "silu", "swish"):
        raise NotImplementedError(f"activation {activation!r} not supported")
    if seq_idx is not None:
        raise NotImplementedError(
            "seq_idx (varlen batching) is not supported by the pure-PyTorch "
            "causal_conv1d fallback")
    dim, width = weight.shape

    if initial_states is None:
        x_padded = F.pad(x, (width - 1, 0))
    else:
        x_padded = torch.cat([initial_states.to(x.dtype), x], dim=-1)

    out = F.conv1d(x_padded, weight.unsqueeze(1), bias=bias,
                   padding=0, groups=dim)

    if activation in ("silu", "swish"):
        out = F.silu(out)

    if return_final_states:
        final_states = x_padded[..., -(width - 1):] if width > 1 else \
            x.new_zeros(x.shape[0], dim, 0)
        if final_states_out is not None:
            final_states_out.copy_(final_states)
            final_states = final_states_out
        return out, final_states
    return out


def causal_conv1d_update_fallback(
    x, conv_state, weight, bias=None, activation=None,
    cache_seqlens=None, conv_state_indices=None, **kwargs,
):
    """Single/multi-step decoding update. Mutates conv_state in place.

    x: (batch, dim) or (batch, dim, seqlen)
    conv_state: (batch, dim, state_len) with state_len >= width - 1
    """
    if activation not in (None, "silu", "swish"):
        raise NotImplementedError(f"activation {activation!r} not supported")
    if cache_seqlens is not None or conv_state_indices is not None:
        raise NotImplementedError(
            "cache_seqlens / conv_state_indices are not supported by the "
            "pure-PyTorch causal_conv1d fallback")

    squeeze = x.dim() == 2
    if squeeze:
        x = x.unsqueeze(-1)
    batch, dim, seqlen = x.shape
    width = weight.shape[-1]
    state_len = conv_state.shape[-1]

    x_full = torch.cat([conv_state.to(x.dtype), x], dim=-1)
    conv_state.copy_(x_full[..., -state_len:].to(conv_state.dtype))

    out = F.conv1d(x_full, weight.unsqueeze(1), bias=bias,
                   padding=0, groups=dim)[..., -seqlen:]
    if activation in ("silu", "swish"):
        out = F.silu(out)
    return out.squeeze(-1) if squeeze else out


def _install() -> bool:
    """Inject the shim unless the real compiled package imports cleanly."""
    if not _HAS_TORCH:
        return False  # nothing imports causal_conv1d without torch anyway
    try:
        import causal_conv1d  # noqa: F401
        return False  # real CUDA build present; leave it alone
    except Exception:
        pass

    mod = ModuleType("causal_conv1d")
    mod.__version__ = "0.0.0+pytorch-fallback"
    mod.causal_conv1d_fn = causal_conv1d_fallback
    mod.causal_conv1d_update = causal_conv1d_update_fallback
    # A real ModuleSpec is required: importlib.util.find_spec() raises
    # "ValueError: causal_conv1d.__spec__ is None" on spec-less fakes.
    mod.__spec__ = ModuleSpec("causal_conv1d", loader=None,
                              origin="mnemonicai.patch_causal shim")
    mod.__spec__.submodule_search_locations = []
    mod.__path__ = []  # mark as package so submodule imports resolve

    iface = ModuleType("causal_conv1d.causal_conv1d_interface")
    iface.causal_conv1d_fn = causal_conv1d_fallback
    iface.causal_conv1d_update = causal_conv1d_update_fallback
    iface.__spec__ = ModuleSpec("causal_conv1d.causal_conv1d_interface",
                                loader=None,
                                origin="mnemonicai.patch_causal shim")
    mod.causal_conv1d_interface = iface

    sys.modules["causal_conv1d"] = mod
    sys.modules["causal_conv1d.causal_conv1d_interface"] = iface
    return True


INSTALLED = _install()
