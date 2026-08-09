#!/usr/bin/env python3
"""Generate huffman/decode_table.odin from RFC 7541 Appendix B codes in TABLE.

Builds a 256-state × 16-nybble FSM. Each transition may emit at most one
symbol (min code length is 5 bits). Flags: ACCEPT (dest is valid end),
SYM (emits symbol), FAIL (invalid prefix), EOS (EOS symbol completed).

Re-run from repo root:
  python3 huffman/gen_decode_table.py
"""
from __future__ import annotations

import os
from pathlib import Path

# Left-aligned codes matching huffman.odin TABLE (0..255 + EOS@256).
TABLE: list[tuple[int, int]] = [
    (13, 0xFFC00000), (23, 0xFFFFB000), (28, 0xFFFFFE20), (28, 0xFFFFFE30),
    (28, 0xFFFFFE40), (28, 0xFFFFFE50), (28, 0xFFFFFE60), (28, 0xFFFFFE70),
    (28, 0xFFFFFE80), (24, 0xFFFFEA00), (30, 0xFFFFFFF0), (28, 0xFFFFFE90),
    (28, 0xFFFFFEA0), (30, 0xFFFFFFF4), (28, 0xFFFFFEB0), (28, 0xFFFFFEC0),
    (28, 0xFFFFFED0), (28, 0xFFFFFEE0), (28, 0xFFFFFEF0), (28, 0xFFFFFF00),
    (28, 0xFFFFFF10), (28, 0xFFFFFF20), (30, 0xFFFFFFF8), (28, 0xFFFFFF30),
    (28, 0xFFFFFF40), (28, 0xFFFFFF50), (28, 0xFFFFFF60), (28, 0xFFFFFF70),
    (28, 0xFFFFFF80), (28, 0xFFFFFF90), (28, 0xFFFFFFA0), (28, 0xFFFFFFB0),
    (6, 0x50000000), (10, 0xFE000000), (10, 0xFE400000), (12, 0xFFA00000),
    (13, 0xFFC80000), (6, 0x54000000), (8, 0xF8000000), (11, 0xFF400000),
    (10, 0xFE800000), (10, 0xFEC00000), (8, 0xF9000000), (11, 0xFF600000),
    (8, 0xFA000000), (6, 0x58000000), (6, 0x5C000000), (6, 0x60000000),
    (5, 0x0), (5, 0x08000000), (5, 0x10000000), (6, 0x64000000),
    (6, 0x68000000), (6, 0x6C000000), (6, 0x70000000), (6, 0x74000000),
    (6, 0x78000000), (6, 0x7C000000), (7, 0xB8000000), (8, 0xFB000000),
    (15, 0xFFF80000), (6, 0x80000000), (12, 0xFFB00000), (10, 0xFF000000),
    (13, 0xFFD00000), (6, 0x84000000), (7, 0xBA000000), (7, 0xBC000000),
    (7, 0xBE000000), (7, 0xC0000000), (7, 0xC2000000), (7, 0xC4000000),
    (7, 0xC6000000), (7, 0xC8000000), (7, 0xCA000000), (7, 0xCC000000),
    (7, 0xCE000000), (7, 0xD0000000), (7, 0xD2000000), (7, 0xD4000000),
    (7, 0xD6000000), (7, 0xD8000000), (7, 0xDA000000), (7, 0xDC000000),
    (7, 0xDE000000), (7, 0xE0000000), (7, 0xE2000000), (7, 0xE4000000),
    (8, 0xFC000000), (7, 0xE6000000), (8, 0xFD000000), (13, 0xFFD80000),
    (19, 0xFFFE0000), (13, 0xFFE00000), (14, 0xFFF00000), (6, 0x88000000),
    (15, 0xFFFA0000), (5, 0x18000000), (6, 0x8C000000), (5, 0x20000000),
    (6, 0x90000000), (5, 0x28000000), (6, 0x94000000), (6, 0x98000000),
    (6, 0x9C000000), (5, 0x30000000), (7, 0xE8000000), (7, 0xEA000000),
    (6, 0xA0000000), (6, 0xA4000000), (6, 0xA8000000), (5, 0x38000000),
    (6, 0xAC000000), (7, 0xEC000000), (6, 0xB0000000), (5, 0x40000000),
    (5, 0x48000000), (6, 0xB4000000), (7, 0xEE000000), (7, 0xF0000000),
    (7, 0xF2000000), (7, 0xF4000000), (7, 0xF6000000), (15, 0xFFFC0000),
    (11, 0xFF800000), (14, 0xFFF40000), (13, 0xFFE80000), (28, 0xFFFFFFC0),
    (20, 0xFFFE6000), (22, 0xFFFF4800), (20, 0xFFFE7000), (20, 0xFFFE8000),
    (22, 0xFFFF4C00), (22, 0xFFFF5000), (22, 0xFFFF5400), (23, 0xFFFFB200),
    (22, 0xFFFF5800), (23, 0xFFFFB400), (23, 0xFFFFB600), (23, 0xFFFFB800),
    (23, 0xFFFFBA00), (23, 0xFFFFBC00), (24, 0xFFFFEB00), (23, 0xFFFFBE00),
    (24, 0xFFFFEC00), (24, 0xFFFFED00), (22, 0xFFFF5C00), (23, 0xFFFFC000),
    (24, 0xFFFFEE00), (23, 0xFFFFC200), (23, 0xFFFFC400), (23, 0xFFFFC600),
    (23, 0xFFFFC800), (21, 0xFFFEE000), (22, 0xFFFF6000), (23, 0xFFFFCA00),
    (22, 0xFFFF6400), (23, 0xFFFFCC00), (23, 0xFFFFCE00), (24, 0xFFFFEF00),
    (22, 0xFFFF6800), (21, 0xFFFEE800), (20, 0xFFFE9000), (22, 0xFFFF6C00),
    (22, 0xFFFF7000), (23, 0xFFFFD000), (23, 0xFFFFD200), (21, 0xFFFEF000),
    (23, 0xFFFFD400), (22, 0xFFFF7400), (22, 0xFFFF7800), (24, 0xFFFFF000),
    (21, 0xFFFEF800), (22, 0xFFFF7C00), (23, 0xFFFFD600), (23, 0xFFFFD800),
    (21, 0xFFFF0000), (21, 0xFFFF0800), (22, 0xFFFF8000), (21, 0xFFFF1000),
    (23, 0xFFFFDA00), (22, 0xFFFF8400), (23, 0xFFFFDC00), (23, 0xFFFFDE00),
    (20, 0xFFFEA000), (22, 0xFFFF8800), (22, 0xFFFF8C00), (22, 0xFFFF9000),
    (23, 0xFFFFE000), (22, 0xFFFF9400), (22, 0xFFFF9800), (23, 0xFFFFE200),
    (26, 0xFFFFF800), (26, 0xFFFFF840), (20, 0xFFFEB000), (19, 0xFFFE2000),
    (22, 0xFFFF9C00), (23, 0xFFFFE400), (22, 0xFFFFA000), (25, 0xFFFFF600),
    (26, 0xFFFFF880), (26, 0xFFFFF8C0), (26, 0xFFFFF900), (27, 0xFFFFFBC0),
    (27, 0xFFFFFBE0), (26, 0xFFFFF940), (24, 0xFFFFF100), (25, 0xFFFFF680),
    (19, 0xFFFE4000), (21, 0xFFFF1800), (26, 0xFFFFF980), (27, 0xFFFFFC00),
    (27, 0xFFFFFC20), (26, 0xFFFFF9C0), (27, 0xFFFFFC40), (24, 0xFFFFF200),
    (21, 0xFFFF2000), (21, 0xFFFF2800), (26, 0xFFFFFA00), (26, 0xFFFFFA40),
    (28, 0xFFFFFFD0), (27, 0xFFFFFC60), (27, 0xFFFFFC80), (27, 0xFFFFFCA0),
    (20, 0xFFFEC000), (24, 0xFFFFF300), (20, 0xFFFED000), (21, 0xFFFF3000),
    (22, 0xFFFFA400), (21, 0xFFFF3800), (21, 0xFFFF4000), (23, 0xFFFFE600),
    (22, 0xFFFFA800), (22, 0xFFFFAC00), (25, 0xFFFFF700), (25, 0xFFFFF780),
    (24, 0xFFFFF400), (24, 0xFFFFF500), (26, 0xFFFFFA80), (23, 0xFFFFE800),
    (26, 0xFFFFFAC0), (27, 0xFFFFFCC0), (26, 0xFFFFFB00), (26, 0xFFFFFB40),
    (27, 0xFFFFFCE0), (27, 0xFFFFFD00), (27, 0xFFFFFD20), (27, 0xFFFFFD40),
    (27, 0xFFFFFD60), (28, 0xFFFFFFE0), (27, 0xFFFFFD80), (27, 0xFFFFFDA0),
    (27, 0xFFFFFDC0), (27, 0xFFFFFDE0), (27, 0xFFFFFE00), (26, 0xFFFFFB80),
    (30, 0xFFFFFFFC),
]

assert len(TABLE) == 257
EOS = 256

DECODE_ACCEPT = 1
DECODE_SYM = 2
DECODE_FAIL = 4
DECODE_EOS = 8


class Node:
    __slots__ = ("ch", "sym", "id", "depth", "all_ones")

    def __init__(self) -> None:
        self.ch: list[Node | None] = [None, None]
        self.sym: int | None = None
        self.id = -1
        self.depth = 0
        self.all_ones = True


def build_trie() -> Node:
    root = Node()
    root.depth = 0
    root.all_ones = True  # empty path is vacuously "all ones" for accept (depth 0)
    for sym, (nbits, code) in enumerate(TABLE):
        n = root
        for i in range(nbits):
            bit = (code >> (31 - i)) & 1
            if n.ch[bit] is None:
                c = Node()
                c.depth = n.depth + 1
                c.all_ones = n.all_ones and bit == 1
                n.ch[bit] = c
            n = n.ch[bit]  # type: ignore[assignment]
            assert n is not None
        assert n.sym is None, f"prefix conflict at sym {sym}"
        n.sym = sym
    return root


def collect_states(root: Node) -> list[Node]:
    """Internal (non-leaf) nodes only — each is an FSM state."""
    out: list[Node] = []

    def walk(n: Node) -> None:
        if n.sym is not None:
            return
        out.append(n)
        for b in (0, 1):
            c = n.ch[b]
            if c is not None:
                walk(c)

    walk(root)
    for i, n in enumerate(out):
        n.id = i
    return out


def is_accept(n: Node) -> bool:
    # Valid end: no leftover bits, or ≤7 bits of EOS prefix (all 1s).
    return n.depth == 0 or (n.all_ones and n.depth <= 7)


def transition(root: Node, start: Node, nybble: int) -> tuple[int, int, int]:
    """Return (next_state_id, flags, sym)."""
    node = start
    flags = 0
    sym_out = 0
    for bi in range(3, -1, -1):
        bit = (nybble >> bi) & 1
        child = node.ch[bit]
        if child is None:
            return 0, DECODE_FAIL, 0
        if child.sym is not None:
            if child.sym == EOS:
                return 0, DECODE_EOS, 0
            flags |= DECODE_SYM
            sym_out = child.sym
            node = root  # resume after emit
        else:
            node = child
    if is_accept(node):
        flags |= DECODE_ACCEPT
    return node.id, flags, sym_out


def emit_odin(states: list[Node], root: Node, path: Path) -> None:
    nstates = len(states)
    assert nstates == 256
    assert root.id == 0

    lines: list[str] = []
    lines.append("// Code generated by huffman/gen_decode_table.py; DO NOT EDIT.")
    lines.append("// 256-state × 16-nybble HPACK Huffman decode FSM (RFC 7541 Appendix B).")
    lines.append("package huffman")
    lines.append("")
    lines.append("// Decode_Entry flags (bitmask).")
    lines.append("DECODE_ACCEPT :: u8(1) // next state is a valid end-of-input (padding OK)")
    lines.append("DECODE_SYM    :: u8(2) // transition emits `sym`")
    lines.append("DECODE_FAIL   :: u8(4) // invalid bit sequence")
    lines.append("DECODE_EOS    :: u8(8) // completed the EOS symbol (protocol error)")
    lines.append("")
    lines.append("Decode_Entry :: struct {")
    lines.append("\tstate: u8, // next FSM state")
    lines.append("\tflags: u8, // DECODE_* bitmask")
    lines.append("\tsym:   u8, // emitted byte when DECODE_SYM set")
    lines.append("}")
    lines.append("")
    lines.append("DECODE_NSTATES :: 256")
    lines.append("")
    lines.append("// Flat table: index = state*16 + nybble (MSB nybble first per input byte).")
    lines.append("@(rodata)")
    lines.append("DECODE_TABLE := [DECODE_NSTATES * 16]Decode_Entry {")

    for st in states:
        row = []
        for nyb in range(16):
            ns, fl, sy = transition(root, st, nyb)
            row.append(f"{{0x{ns:02X}, 0x{fl:02X}, 0x{sy:02X}}}")
        # 4 entries per source line for readability
        for i in range(0, 16, 4):
            chunk = ", ".join(row[i : i + 4])
            comma = "," if not (st.id == nstates - 1 and i == 12) else ","
            lines.append(f"\t{chunk}{comma}")
        lines.append("")  # blank between states

    # strip trailing blank and ensure closing
    while lines and lines[-1] == "":
        lines.pop()
    lines.append("}")
    lines.append("")
    lines.append("// True if ending the input in this state is valid (≤7 all-1s EOS padding).")
    lines.append("@(rodata)")
    lines.append("DECODE_STATE_ACCEPT := [DECODE_NSTATES]bool {")
    acc = ["true" if is_accept(s) else "false" for s in states]
    for i in range(0, nstates, 16):
        chunk = ", ".join(acc[i : i + 16])
        lines.append(f"\t{chunk},")
    lines.append("}")
    lines.append("")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {path} ({nstates} states, {nstates * 16} entries)")
    n_acc = sum(1 for s in states if is_accept(s))
    print(f"accept states: {n_acc}")


def main() -> None:
    root = build_trie()
    states = collect_states(root)
    if len(states) != 256:
        raise SystemExit(f"expected 256 internal states, got {len(states)}")
    out = Path(__file__).resolve().parent / "decode_table.odin"
    emit_odin(states, root, out)

    # Sanity: encode empty → ok; single '0' (5 zero bits + 3 ones pad)
    # Spot-check transition from root on nybble 0 (0000): stays incomplete depth 4, not accept
    ns, fl, sy = transition(root, root, 0x0)
    assert fl & DECODE_FAIL == 0 and fl & DECODE_SYM == 0
    # 0xF from root: four 1-bits → depth 4 all-ones, ACCEPT
    ns, fl, sy = transition(root, root, 0xF)
    assert fl & DECODE_ACCEPT, hex(fl)


if __name__ == "__main__":
    main()
