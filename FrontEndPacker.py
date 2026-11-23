TYPE = "S"

def pack_request(town_code):
    body = f"NB1 {TYPE} {town_code}"
    checksum = sum(body.encode("ascii")) % 10000
    return f"{body} K{checksum:04d}"