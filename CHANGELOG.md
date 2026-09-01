# gren-bignum 1.0.0

Renamed from `gilramir/gren-bigint`, because there is more than one kind of
number in it now. A new name is a new package as far as the registry is
concerned, so the version starts over; `gilramir/gren-bigint` 1.0.0 stays where
it is.

- **New: `BigDecimal`** — exact decimal numbers, as an unscaled `BigInt` over a
  power of ten. Arithmetic that never rounds, division that is either exact or
  `Nothing`, division to a number of places that always answers, and the seven
  IEEE 754 roundings. Trailing zeroes are stripped, so `1.50 == 1.5` and `==`
  is numeric equality.
- **`toStringWithBase` now slices** for bases 2, 4, 8 and 16, whose digits
  divide a 24-bit limb evenly: each limb is written as a fixed run of digits
  and the runs are concatenated, with no division at any size. Formatting an
  8192-bit number in hex three hundred times goes from 477 ms to 38 ms. Other
  bases, base 32 among them, divide as before. Same output either way.
- `BigInt` is otherwise unchanged, and its API is the whole of what
  `BigDecimal` is built on.

# gren-bigint 1.0.0

First release.
