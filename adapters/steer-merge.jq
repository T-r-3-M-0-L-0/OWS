def field($key): if has($key) then [.[$key]] else [] end;

# The arrays around values distinguish a missing key from an explicit null.
def merge($base; $draft; $live; $path):
    if $draft==$base then $live
    elif $live==$base or $live==$draft then $draft
    elif all($base,$draft,$live; length==1 and (.[0]|type)=="object") then
        [reduce (($base[0]|keys)+($draft[0]|keys)+($live[0]|keys)|unique[]) as $key ({};
            merge(($base[0]|field($key)); ($draft[0]|field($key)); ($live[0]|field($key)); $path+[$key]) as $value |
            if $value==[] then . else .[$key]=$value[0] end)]
    else error("Конфликт изменений: " + ($path|join(".")))
    end;

merge($base; $draft; $live; [])[0]
