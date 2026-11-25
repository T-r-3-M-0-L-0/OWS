def pick($value; $allowed):
    if ($allowed | index($value)) != null then $value else error("unsupported option") end;
def choice($value):
    if ($value|type) == "string" and (.outputs|has($value)) then $value else error("unknown output") end;
def smallint($value):
    if ($value|type) == "number" and $value >= 0 and $value <= 86400 and $value == ($value|floor)
    then $value else error("invalid integer") end;
def macs:
    if type=="array" and length<=256 and all(.[]; type=="string" and test("^([0-9a-f]{2}:){5}[0-9a-f]{2}$"))
    then unique else error("invalid device group") end;
def generated:
    .name as $n | ["OWS: bypass devices","OWS: device exceptions","OWS: full VPN","OWS: exclusions"] | index($n) != null;

$change[0] as $c |
if $c.type=="node" then
    .outputs[$c.output] |= (if $c.node == -1 then del(.nodes) else .nodes=($c.node|smallint(.)) end)
elif $c.type=="connection" then
    choice($c.output) as $out |
    [.outputs | to_entries[] | select(.value.kind!="direct" and .value.kind!="block") | .key] as $available |
    if ($available | index($out)) == null then error("unsupported routing target") else
        .rules |= map(.out as $old | if (generated|not) and ($available|index($old)) != null then .out=$out else . end)
    end
elif $c.type=="service" then
    choice($c.output) as $out |
    if ($c.index|type)!="number" or $c.index!=($c.index|floor) or $c.index<0 or
        $c.index>= (.rules|length) or (.rules[$c.index]|generated)
    then error("unknown service rule") else
        if $domains != "" then
            .lists[$service_key] = {domains_file:[$domains]} |
            .rules[$c.index].to |= (if $c.append==true then
                (if type=="array" then . elif type=="string" then [.] else [] end) + [$service_key]
                else [$service_key] end)
        else . end |
        .rules[$c.index].out=$out |
        .rules[$c.index].enabled=($c.enabled == true)
    end
elif $c.type=="service_custom" then
    choice($c.output) as $out |
    if $domains=="" or ($c.name|type)!="string" or
        ($c.name|length)<1 or ($c.name|length)>100 or
        ($c.name|test("^[[:space:]]*$|[[:cntrl:]]|^OWS:")) then error("invalid service name")
    else
        .lists[$service_key]={domains_file:[$domains]} |
        .rules += ([{name:$c.name, to:[$service_key], out:$out}] |
            if $policy[0].mode=="allow" then map(.for=["ows_allowed"]) else . end)
    end
elif $c.type=="catalog_service" then
    choice($c.output) as $out |
    $catalog_service[0] as $service |
    if $service.id!=$c.id or ((.lists // {}) | has($service.id)) then error("invalid catalog service") else
        .lists[$service.id]=$service.list |
        .rules += ([{name:$service.name, to:[$service.id], out:$out}] |
            if $policy[0].mode=="allow" then map(.for=["ows_allowed"]) else . end)
    end
elif $c.type=="settings" then
    choice($c.output) as $out |
    (.lists // {}) as $lists |
    any(.rules[] | select(.out==$out and (generated|not));
        any((.to | if type=="array" then .[] else . end); ($lists[.].srs // [] | length)>0)) as $uses_srs |
    if $uses_srs and $c.quic=="block" then error("quic block with srs")
    elif $uses_srs and $c.torrent!="allow" then error("torrent policy with srs")
    else . end |
    if ($c.rule_dns // "") != "" and ((.dns.upstreams // {}) | has($c.rule_dns) | not)
    then error("unknown DNS upstream") else . end |
    .outputs[$out].on_fail=pick($c.on_fail; ["direct","drop","zapret"]) |
    .dns.mode=pick($c.dns; ["fakeip","realip"]) |
    .dns.cache_ttl.min=smallint($c.ttl_min) |
    .dns.cache_ttl.max=smallint($c.ttl_max) |
    .dns.cache_ttl.negative=smallint($c.ttl_negative) |
    if .dns.cache_ttl.min > .dns.cache_ttl.max then error("invalid TTL range") else . end |
    .rules |= map(if .out==$out and (generated|not) then
        if pick($c.quic; ["allow","block"])=="allow" then del(.quic) else .quic=$c.quic end |
        if pick($c.torrent; ["allow","direct","block"])=="allow" then del(.torrent) else .torrent=$c.torrent end |
        .resolve=pick($c.resolve; ["realip","fakeip"]) |
        if ($c.rule_dns // "") != "" then .dns=$c.rule_dns else . end
    else . end)
elif $c.type=="devices" or $c.type=="exclusions" then
    $policy[0] as $p |
    pick($p.mode; ["all","allow","deny"]) as $mode |
    ($p.devices|macs) as $devices | ($p.full|macs) as $full |
    if $mode!="all" and ($devices|length)==0 then error("device list is empty") else . end |
    if any($full[]; . as $mac | ($devices|index($mac)) as $hit |
        ($mode=="allow" and $hit==null) or ($mode=="deny" and $hit!=null))
    then error("a full-VPN device is excluded") else . end |
    (if ($full|length)>0 then
         choice($p.full_output) as $out |
         if (.outputs[$out].kind|IN("group","tunnel")) then $out else error("full VPN requires VPN output") end
     else null end) as $vpn |
    .rules |= map(select(generated|not) | if .for==["ows_allowed"] then del(.for) else . end) |
    if $mode!="all" and any(.rules[]; (.for // ["lan"]) != ["lan"] or .scope=="device")
    then error("existing per-device rules require a separate migration") else . end |
    .outputs.ows_direct={kind:"direct"} |
    .clients |= ((. // {}) | del(.ows_allowed,.ows_denied,.ows_full)) |
    .lists |= ((. // {}) | del(.ows_exclusions)) |
    if $mode=="allow" then
        .clients.ows_allowed={mac:$devices} | .rules |= map(.for=["ows_allowed"])
    elif $mode=="deny" then .clients.ows_denied={mac:$devices} else . end |
    if $vpn then .clients.ows_full={mac:$full} else . end |
    if $ex_domains != "" or $ex_ips != "" then
        .lists.ows_exclusions=((if $ex_domains != "" then {domains_file:[$ex_domains]} else {} end) +
                               (if $ex_ips != "" then {prefixes_file:[$ex_ips]} else {} end))
    else . end |
    .rules = (
        (if $mode=="deny" then [{name:"OWS: bypass devices",for:["ows_denied"],scope:"device",to:["all"],out:"ows_direct"}] else [] end)
        + (if ($ex_domains != "" or $ex_ips != "") and $vpn then [{name:"OWS: device exceptions",for:["ows_full"],scope:"device",to:["ows_exclusions"],out:"ows_direct",resolve:"realip"}] else [] end)
        + (if $vpn then [{name:"OWS: full VPN",for:["ows_full"],scope:"device",to:["all"],out:$vpn}] else [] end)
        + (if $ex_domains != "" or $ex_ips != "" then [{name:"OWS: exclusions",to:["ows_exclusions"],out:"ows_direct",resolve:"realip"}] else [] end)
        + .rules
    )
else error("unknown edit") end
