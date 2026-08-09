// Package huffman implements the canonical HTTP Huffman code (RFC 7541
// Appendix B) used by HPACK (HTTP/2). Callers use huffman.encode /
// huffman.decode / huffman.TABLE.
//
// TABLE is the 257-symbol table (0..255 + EOS at 256), ported from nghttp3's
// huffman_sym_table. Each `code` is the Huffman code stored LEFT-ALIGNED in the
// high `nbits` bits of a u32. The decoder is a correct-but-simple bit-walk
// (linear table match per emitted symbol); the FSM/state-table decode is a
// later optimization.
package huffman

Code :: struct {
	nbits: u8,  // code length in bits (5..30)
	code:  u32, // code value, left-aligned in the top `nbits` bits
}

EOS :: 256

Error :: enum {
	None,
	Invalid_Code,
	Invalid_Padding,
	EOS_In_Input,
}

// Length in bytes that `data` occupies when Huffman-encoded.
encoded_len :: proc(data: []u8) -> int {
	bits := 0
	for b in data do bits += int(TABLE[b].nbits)
	return (bits + 7) / 8
}

// Encode `data` into `dst` (must be >= encoded_len(data)). The final partial
// byte is padded with the EOS prefix (all 1s) per RFC 7541 §5.2. Returns the
// number of bytes written.
encode :: proc(dst: []u8, data: []u8) -> int {
	acc:   u64 // bit accumulator; valid bits live in the low `nbits` positions
	nbits: uint
	out:   int
	for b in data {
		sym := TABLE[b]
		ln := uint(sym.nbits)
		acc = (acc << ln) | u64(sym.code >> (32 - ln))
		nbits += ln
		for nbits >= 8 {
			nbits -= 8
			dst[out] = u8((acc >> nbits) & 0xFF)
			out += 1
		}
	}
	if nbits > 0 {
		pad := 8 - nbits
		dst[out] = u8(((acc << pad) | ((u64(1) << pad) - 1)) & 0xFF)
		out += 1
	}
	return out
}

// Decode `src` Huffman bytes, appending plaintext to `dst`. Trailing bits (<8)
// must be all-1s EOS padding; an embedded EOS symbol is a protocol error.
decode :: proc(dst: ^[dynamic]u8, src: []u8) -> Error {
	cur: u32 // accumulated bits, right-aligned
	cur_len: u8
	for byte_ in src {
		for bit := 7; bit >= 0; bit -= 1 {
			cur = (cur << 1) | u32((byte_ >> uint(bit)) & 1)
			cur_len += 1
			if cur_len > 30 do return .Invalid_Code
			for sym, i in TABLE {
				if sym.nbits != cur_len do continue
				if (sym.code >> (32 - uint(cur_len))) == cur {
					if i == EOS do return .EOS_In_Input
					append(dst, u8(i))
					cur, cur_len = 0, 0
					break
				}
			}
		}
	}
	if cur_len > 7 do return .Invalid_Padding
	if cur_len > 0 {
		mask := u32((u64(1) << uint(cur_len)) - 1)
		if cur != mask do return .Invalid_Padding // padding must be all 1s
	}
	return .None
}

@(rodata)
TABLE := [257]Code {
	{13, 0xFFC00000}, {23, 0xFFFFB000}, {28, 0xFFFFFE20}, {28, 0xFFFFFE30},
	{28, 0xFFFFFE40}, {28, 0xFFFFFE50}, {28, 0xFFFFFE60}, {28, 0xFFFFFE70},
	{28, 0xFFFFFE80}, {24, 0xFFFFEA00}, {30, 0xFFFFFFF0}, {28, 0xFFFFFE90},
	{28, 0xFFFFFEA0}, {30, 0xFFFFFFF4}, {28, 0xFFFFFEB0}, {28, 0xFFFFFEC0},
	{28, 0xFFFFFED0}, {28, 0xFFFFFEE0}, {28, 0xFFFFFEF0}, {28, 0xFFFFFF00},
	{28, 0xFFFFFF10}, {28, 0xFFFFFF20}, {30, 0xFFFFFFF8}, {28, 0xFFFFFF30},
	{28, 0xFFFFFF40}, {28, 0xFFFFFF50}, {28, 0xFFFFFF60}, {28, 0xFFFFFF70},
	{28, 0xFFFFFF80}, {28, 0xFFFFFF90}, {28, 0xFFFFFFA0}, {28, 0xFFFFFFB0},
	{6, 0x50000000}, {10, 0xFE000000}, {10, 0xFE400000}, {12, 0xFFA00000},
	{13, 0xFFC80000}, {6, 0x54000000}, {8, 0xF8000000}, {11, 0xFF400000},
	{10, 0xFE800000}, {10, 0xFEC00000}, {8, 0xF9000000}, {11, 0xFF600000},
	{8, 0xFA000000}, {6, 0x58000000}, {6, 0x5C000000}, {6, 0x60000000},
	{5, 0x0}, {5, 0x08000000}, {5, 0x10000000}, {6, 0x64000000},
	{6, 0x68000000}, {6, 0x6C000000}, {6, 0x70000000}, {6, 0x74000000},
	{6, 0x78000000}, {6, 0x7C000000}, {7, 0xB8000000}, {8, 0xFB000000},
	{15, 0xFFF80000}, {6, 0x80000000}, {12, 0xFFB00000}, {10, 0xFF000000},
	{13, 0xFFD00000}, {6, 0x84000000}, {7, 0xBA000000}, {7, 0xBC000000},
	{7, 0xBE000000}, {7, 0xC0000000}, {7, 0xC2000000}, {7, 0xC4000000},
	{7, 0xC6000000}, {7, 0xC8000000}, {7, 0xCA000000}, {7, 0xCC000000},
	{7, 0xCE000000}, {7, 0xD0000000}, {7, 0xD2000000}, {7, 0xD4000000},
	{7, 0xD6000000}, {7, 0xD8000000}, {7, 0xDA000000}, {7, 0xDC000000},
	{7, 0xDE000000}, {7, 0xE0000000}, {7, 0xE2000000}, {7, 0xE4000000},
	{8, 0xFC000000}, {7, 0xE6000000}, {8, 0xFD000000}, {13, 0xFFD80000},
	{19, 0xFFFE0000}, {13, 0xFFE00000}, {14, 0xFFF00000}, {6, 0x88000000},
	{15, 0xFFFA0000}, {5, 0x18000000}, {6, 0x8C000000}, {5, 0x20000000},
	{6, 0x90000000}, {5, 0x28000000}, {6, 0x94000000}, {6, 0x98000000},
	{6, 0x9C000000}, {5, 0x30000000}, {7, 0xE8000000}, {7, 0xEA000000},
	{6, 0xA0000000}, {6, 0xA4000000}, {6, 0xA8000000}, {5, 0x38000000},
	{6, 0xAC000000}, {7, 0xEC000000}, {6, 0xB0000000}, {5, 0x40000000},
	{5, 0x48000000}, {6, 0xB4000000}, {7, 0xEE000000}, {7, 0xF0000000},
	{7, 0xF2000000}, {7, 0xF4000000}, {7, 0xF6000000}, {15, 0xFFFC0000},
	{11, 0xFF800000}, {14, 0xFFF40000}, {13, 0xFFE80000}, {28, 0xFFFFFFC0},
	{20, 0xFFFE6000}, {22, 0xFFFF4800}, {20, 0xFFFE7000}, {20, 0xFFFE8000},
	{22, 0xFFFF4C00}, {22, 0xFFFF5000}, {22, 0xFFFF5400}, {23, 0xFFFFB200},
	{22, 0xFFFF5800}, {23, 0xFFFFB400}, {23, 0xFFFFB600}, {23, 0xFFFFB800},
	{23, 0xFFFFBA00}, {23, 0xFFFFBC00}, {24, 0xFFFFEB00}, {23, 0xFFFFBE00},
	{24, 0xFFFFEC00}, {24, 0xFFFFED00}, {22, 0xFFFF5C00}, {23, 0xFFFFC000},
	{24, 0xFFFFEE00}, {23, 0xFFFFC200}, {23, 0xFFFFC400}, {23, 0xFFFFC600},
	{23, 0xFFFFC800}, {21, 0xFFFEE000}, {22, 0xFFFF6000}, {23, 0xFFFFCA00},
	{22, 0xFFFF6400}, {23, 0xFFFFCC00}, {23, 0xFFFFCE00}, {24, 0xFFFFEF00},
	{22, 0xFFFF6800}, {21, 0xFFFEE800}, {20, 0xFFFE9000}, {22, 0xFFFF6C00},
	{22, 0xFFFF7000}, {23, 0xFFFFD000}, {23, 0xFFFFD200}, {21, 0xFFFEF000},
	{23, 0xFFFFD400}, {22, 0xFFFF7400}, {22, 0xFFFF7800}, {24, 0xFFFFF000},
	{21, 0xFFFEF800}, {22, 0xFFFF7C00}, {23, 0xFFFFD600}, {23, 0xFFFFD800},
	{21, 0xFFFF0000}, {21, 0xFFFF0800}, {22, 0xFFFF8000}, {21, 0xFFFF1000},
	{23, 0xFFFFDA00}, {22, 0xFFFF8400}, {23, 0xFFFFDC00}, {23, 0xFFFFDE00},
	{20, 0xFFFEA000}, {22, 0xFFFF8800}, {22, 0xFFFF8C00}, {22, 0xFFFF9000},
	{23, 0xFFFFE000}, {22, 0xFFFF9400}, {22, 0xFFFF9800}, {23, 0xFFFFE200},
	{26, 0xFFFFF800}, {26, 0xFFFFF840}, {20, 0xFFFEB000}, {19, 0xFFFE2000},
	{22, 0xFFFF9C00}, {23, 0xFFFFE400}, {22, 0xFFFFA000}, {25, 0xFFFFF600},
	{26, 0xFFFFF880}, {26, 0xFFFFF8C0}, {26, 0xFFFFF900}, {27, 0xFFFFFBC0},
	{27, 0xFFFFFBE0}, {26, 0xFFFFF940}, {24, 0xFFFFF100}, {25, 0xFFFFF680},
	{19, 0xFFFE4000}, {21, 0xFFFF1800}, {26, 0xFFFFF980}, {27, 0xFFFFFC00},
	{27, 0xFFFFFC20}, {26, 0xFFFFF9C0}, {27, 0xFFFFFC40}, {24, 0xFFFFF200},
	{21, 0xFFFF2000}, {21, 0xFFFF2800}, {26, 0xFFFFFA00}, {26, 0xFFFFFA40},
	{28, 0xFFFFFFD0}, {27, 0xFFFFFC60}, {27, 0xFFFFFC80}, {27, 0xFFFFFCA0},
	{20, 0xFFFEC000}, {24, 0xFFFFF300}, {20, 0xFFFED000}, {21, 0xFFFF3000},
	{22, 0xFFFFA400}, {21, 0xFFFF3800}, {21, 0xFFFF4000}, {23, 0xFFFFE600},
	{22, 0xFFFFA800}, {22, 0xFFFFAC00}, {25, 0xFFFFF700}, {25, 0xFFFFF780},
	{24, 0xFFFFF400}, {24, 0xFFFFF500}, {26, 0xFFFFFA80}, {23, 0xFFFFE800},
	{26, 0xFFFFFAC0}, {27, 0xFFFFFCC0}, {26, 0xFFFFFB00}, {26, 0xFFFFFB40},
	{27, 0xFFFFFCE0}, {27, 0xFFFFFD00}, {27, 0xFFFFFD20}, {27, 0xFFFFFD40},
	{27, 0xFFFFFD60}, {28, 0xFFFFFFE0}, {27, 0xFFFFFD80}, {27, 0xFFFFFDA0},
	{27, 0xFFFFFDC0}, {27, 0xFFFFFDE0}, {27, 0xFFFFFE00}, {26, 0xFFFFFB80},
	{30, 0xFFFFFFFC},
}
