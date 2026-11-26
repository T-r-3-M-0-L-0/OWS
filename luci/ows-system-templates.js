'use strict';
'require baseclass';
'require view.ows-service as serviceView';

function enabled(value) { return value ? _('Включено') : _('Выключено'); }

var control = {
    label:_('Управление'),
    select:function(data) { return data.control; },
    value:function(state) {
        switch (state && state.owner) {
        case 'ows': return 'OWS';
        case 'zapret-manager': return 'Zapret-Manager';
        case 'pending': return _('Ожидается восстановление после передачи');
        case 'repair': return _('Повторите передачу после обновления Zapret-Manager');
        default: return _('Состояние управления недоступно');
        }
    },
    action:'takeover',
    actionLabel:_('Передать управление OWS')
};

var engines = [['zapret','Zapret'],['zapret2','Zapret2']];
var dnsModes = {isp:_('DNS провайдера'),yandex:_('Яндекс DNS'),off:_('Выключено')};
var modules = {
    quic: {
        label:_('Блокировка QUIC'),
        description:_('Правила файрвола отклоняют UDP 80 и 443 из зоны LAN в WAN.'),
        fields:[
            {label:_('Состояние'),value:function(data) {
                if (data.problem) return data.problem;
                if (!data.installed) return _('Зоны или firewall4 недоступны');
                if (data.enabled_rules === 2 && data.live_rules === 2) return _('Включена');
                if (!data.enabled_rules && !data.live_rules) return _('Выключена');
                return _('Правила применены частично');
            }},
            {label:_('Зоны'),value:function(data) { return data.lan && data.wan ? data.lan + ' → ' + data.wan : ''; }}
        ],
        actions:[
            {id:'quic:on',label:_('Включить блокировку'),enabled:function(data) {
                return data.enabled_rules !== 2 || data.live_rules !== 2;
            }},
            {id:'quic:off',label:_('Выключить блокировку'),enabled:function(data) {
                return data.enabled_rules > 0 || data.live_rules > 0;
            }}
        ]
    },
    ipv6: {
        label:_('IPv6 в Zapret'),
        description:_('Управляет обработкой IPv6 в выбранном движке Zapret.'),
        fields:[{label:_('Маршрут IPv6 в интернет'),value:function(data) { return data.route ? _('Есть') : _('Отсутствует'); }}]
            .concat(engines.map(function(engine) {
                return {label:engine[1],value:function(data) {
                    var state = data[engine[0]] || {};
                    return state.installed ? enabled(state.enabled) : _('Не установлен');
                }};
            })),
        actions:engines.flatMap(function(engine) {
            return [true,false].map(function(mode) {
                return {id:'ipv6:' + engine[0] + ':' + (mode ? 'on' : 'off'),
                    label:(mode ? _('Включить IPv6') : _('Выключить IPv6')) + ' · ' + engine[1],
                    requiresInstalled:false,
                    visible:function(data) { return data[engine[0]] && data[engine[0]].installed; },
                    enabled:function(data) { return !!data[engine[0]].enabled !== mode && (!mode || data.route); }};
            });
        })
    },
    network: {
        label:_('Сетевые исключения'),
        description:_('Исключение исходящего трафика VPN из обработки Zapret и отдельный DNS для .ru, .su и .рф.'),
        control:{
            select:function(data) {
                var available = data.control && data.control.ready;
                return {ready:available && data.managed,can_takeover:available && !data.managed,
                    owner:available && data.managed ? 'ows' : 'pending'};
            },
            value:function(state) { return state.ready ? 'OWS' : _('Ожидает передачи'); },
            action:'net:takeover'
        },
        fields:[
            {label:_('Исключение VPN'),value:function(data) {
                return data.vpn === 'on' && !data.vpn_active ? _('Ожидает применения') : data.vpn ? enabled(data.vpn === 'on') : '';
            }},
            {label:_('DNS для .ru, .su, .рф'),value:function(data) { return dnsModes[data.dns]; }},
            {label:_('DNS-серверы'),visible:function(data) { return !!data.resolvers; },value:function(data) { return data.resolvers; }},
            {label:_('Правила dnsmasq'),visible:function(data) { return data.rules != null; },value:function(data) { return data.rules; }}
        ],
        actions:[
            {id:'net:check',label:_('Сверить правила'),requiresInstalled:false,visible:function(data) { return data.managed; }},
            {id:'net:vpn:on',label:_('Исключить трафик VPN'),requiresInstalled:false,visible:function(data) { return data.vpn === 'off'; }},
            {id:'net:vpn:off',label:_('Вернуть обработку VPN'),requiresInstalled:false,visible:function(data) { return data.vpn === 'on'; }}
        ].concat(Object.keys(dnsModes).map(function(mode) {
            return {id:'net:dns:' + mode,label:mode === 'off' ? _('Выключить отдельный DNS') : dnsModes[mode],requiresInstalled:false,
                visible:function(data) { return data.managed && data.dns !== mode; }};
        }))
    },
    zram: {
        label:_('ZRAM — сжатая память'),
        description:_('Сжатая подкачка в оперативной памяти. Пакет устанавливается из репозитория OpenWrt.'),
        fields:[
            {label:_('Состояние'),value:function(data) { return data.running ? _('Работает') : data.installed ? _('Выключена') : _('Пакет не установлен'); }},
            {label:_('Оперативная память'),value:function(data) { return data.ram_mb + ' ' + _('МиБ'); }},
            {label:_('Автозапуск'),visible:function(data) { return data.installed; },value:function(data) { return enabled(data.enabled); }},
            {label:_('Подкачка'),visible:function(data) { return data.running; },value:function(data) {
                return data.used_mb + ' / ' + data.size_mb + ' ' + _('МиБ') + (data.algorithm ? ' · ' + data.algorithm : '');
            }}
        ],
        actions:[
            {id:'zram:install',label:_('Установить и включить ZRAM'),requiresInstalled:false,
                visible:function(data) { return !data.installed; },enabled:function(data) { return !!data.package_manager; }},
            {id:'zram:on',label:_('Включить ZRAM'),visible:function(data) { return data.installed && (!data.running || !data.enabled); }},
            {id:'zram:off',label:_('Выключить ZRAM'),visible:function(data) { return data.installed && (data.running || data.enabled); },
                confirmation:_('Остановить сжатую подкачку и отключить её автозапуск?')}
        ],
        form:{label:_('Параметры следующего запуска'),submitLabel:_('Сохранить параметры'),
            visible:function(data) { return data.installed; },
            fields:[
                {name:'size',label:_('Размер, МиБ (0 — автоматически)'),min:0,max:function(data) { return data.ram_mb; },
                    value:function(data) { return data.configured_size; }},
                {name:'algorithm',label:_('Алгоритм сжатия'),value:function(data) { return data.configured_algorithm; },
                    options:function(data) {
                        var algorithms = new Set(data.algorithms || []);
                        if (data.configured_algorithm !== 'auto') algorithms.add(data.configured_algorithm);
                        return [{value:'auto',label:_('По умолчанию')}].concat(Array.from(algorithms).map(function(name) {
                            return {value:name,label:name};
                        }));
                    }},
                {name:'priority',label:_('Приоритет подкачки'),min:0,max:32767,value:function(data) { return data.priority; }}
            ],
            action:function(fields) { return ['zram','configure',fields.size,fields.algorithm,fields.priority].join(':'); }}
    }
};

return baseclass.extend({
    tabs: function(followJob, overrides) {
        return Object.keys(modules).map(function(id) {
            var override = overrides && overrides[id];
            var template = Object.assign({statusMethod:'system_info',actionMethod:'system_action',
                select:function(data) { return Object.assign({}, data[id], {control:data.control}); }}, modules[id], override,
                {control:Object.assign({}, control, modules[id].control, override && override.control)});
            return serviceView.tab({id:'system-' + id,name:template.label}, followJob, template);
        });
    }
});
