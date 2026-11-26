# Character checks compatible with both OpenWrt jq variants.
def ascii_allowed($characters):
    (explode - ($characters | explode)) == [];

def ascii_alnum: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

def identifier($max):
    length > 0 and length <= $max
    and (.[0:1] | ascii_allowed(ascii_alnum + "_"))
    and ascii_allowed(ascii_alnum + "_-");

def control_code: . < 32 or (. >= 127 and . <= 159);

def whitespace_code:
    (. >= 9 and . <= 13) or . == 32 or . == 133 or . == 160 or . == 5760
    or (. >= 8192 and . <= 8202) or . == 8232 or . == 8233 or . == 8239
    or . == 8287 or . == 12288;

def strip_controls: explode | map(select(control_code | not)) | implode;

def url_parts:
    index("://") as $separator | select($separator != null and $separator > 0)
    | . as $url
    | .[:$separator] as $scheme
    | select(($scheme[0:1] | ascii_allowed("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"))
        and ($scheme | ascii_allowed(ascii_alnum + "+.-")))
    | $url[$separator + 3:] | split("/")[0] | split("?")[0] | split("#")[0] | select(length > 0)
    | {scheme: $scheme, authority: .};

def mac_address($separator):
    split($separator) | length == 6 and all(.[]; length == 2 and ascii_allowed("0123456789abcdef"));
