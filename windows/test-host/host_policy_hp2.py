"""Lossless HP2 fixture codec; independent of the production native encoder."""


def digits(value, width):
    if not 0 <= value < 1 << (6 * width):
        raise ValueError('HP2 numeric bounds')
    return bytes(32 + ((value >> (6 * i)) & 63) for i in reversed(range(width)))


def request(serial, kind, a, b, c):
    if not 1 <= kind <= 12 or not 0 <= serial < 1 << 64:
        raise ValueError('HP2 envelope bounds')
    if any(not 0 <= value <= 262143 for value in (a, b, c)) or (kind == 1 and a > 1):
        raise ValueError('HP2 input bounds')
    scalar = b if kind == 4 else a if kind in (3, 8) else 0
    return b'HP2Q' + digits(serial, 11) + bytes(
        [32 + kind, 32 + min(a, 2), 32 + min(b, 2), 32 + min(c, 2)]) + digits(scalar, 3) + b'\n'


def reply(serial, decision):
    return b'HP2R' + digits(serial, 11) + digits(decision, 3) + b'\n'
