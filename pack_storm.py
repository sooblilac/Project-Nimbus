#backend packer

from datetime import datetime

TYPE = "S" #Type of message, S for storm.

class PackError(ValueError):
    """A storm message field is invalid or outside the supported range."""


def pack_storm(town_code, issued_at, warning_level, rain, gusts_kph):
    if warning_level not in {"0", "1", "2", "3", "4", "5"}:
        raise PackError("warning_level must be a string from 0 to 5")

    if type(rain) is not int or not 0 <= rain <= 4:
        raise PackError("rain must be an integer from 0 to 4")

    if type(gusts_kph) is not int or not 0 <= gusts_kph <= 500:
        raise PackError("gusts_kph must be an integer from 0 to 500")

#NB1 can used for identification of the message, and K is used to identify the checksum.
    body = (
        f"NB1 {TYPE} {town_code} W{warning_level} R{rain} "
        f"G{gusts_kph} T{issued_at:%H%M}"
    )
    checksum = sum(body.encode("ascii")) % 10000
    return f"{body} K{checksum:04d}"