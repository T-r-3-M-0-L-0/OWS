'use strict';
'require baseclass';
'require rpc';
'require view.ows-native as nativeView';
'require view.ows-ui as owsUI';

var info = rpc.declare({object:'ows',method:'dns_info'});
var check = rpc.declare({object:'ows',method:'dns_check',params:['domain']});
var draftStatus = rpc.declare({object:'ows',method:'adblock_draft'});
var draftAction = rpc.declare({object:'ows',method:'adblock_action',params:['action','change']});

function checkForm(followJob, load, domain) {
    var notice = E('p', {role:'status'});
    var log = E('pre', {class:'ows-job-output',hidden:''});
    var form = owsUI.form(domain ? [owsUI.field(_('Домен'), domain)] : [],
        domain ? _('Проверить домен') : _('Проверить DNS'), function() {
        var name = domain ? domain.value.trim().replace(/\.$/, '') : '';
        if (domain && !name) {
            notice.textContent = _('Введите доменное имя');
            return;
        }
        log.hidden = true;
        notice.textContent = _('Ставим проверку DNS в очередь…');
        return owsUI.job(check(name), followJob, true).then(function(result) {
            notice.textContent = result.status.phase === 'done' ? _('Проверка завершена') : _('Проверка выявила сбой');
            log.textContent = result.output;
            log.hidden = !result.output;
            load();
        }).catch(function(error) { notice.textContent = error.message; });
    });
    return E('div', {}, [form, notice, log]);
}

function timestamp(value) {
    return value > 0 ? new Date(value * 1000).toLocaleString() : '—';
}

function external(label, url) {
    return E('a', {href:url,target:'_blank',rel:'noopener noreferrer'}, label);
}

function adblockExceptions(data, submit) {
    function editor(title, value) {
        var input = E('textarea', {rows:5,maxlength:30000,spellcheck:'false',class:'cbi-input-text',placeholder:'example.org'});
        input.value = value;
        return {input:input, field:owsUI.field(title, input)};
    }
    var allow = editor(_('Белый список'), data.allow);
    var block = editor(_('Чёрный список'), data.block);
    var selected = new Set(data.excluded_macs);
    var devices = new Map(data.devices.map(function(device) { return [device.mac, device]; }));
    data.excluded_macs.forEach(function(mac) { if (!devices.has(mac)) devices.set(mac, {mac:mac}); });
    var list = E('div');
    var mac = E('input', {type:'text',maxlength:17,class:'cbi-input-text',placeholder:'aa:bb:cc:dd:ee:ff','aria-label':_('MAC-адрес')});
    var note = E('p', {role:'status'});

    function renderDevices() {
        list.replaceChildren.apply(list, Array.from(devices.values()).map(function(device) {
            var box = E('input', {type:'checkbox'});
            box.checked = selected.has(device.mac);
            box.addEventListener('change', function() {
                if (box.checked) selected.add(device.mac);
                else selected.delete(device.mac);
            });
            return E('div', {}, E('label', {}, [box, ' ', [device.name, device.ip, device.mac].filter(Boolean).join(' · ')]));
        }));
    }

    function addDevice() {
        var value = mac.value.trim().toLowerCase().replace(/-/g, ':');
        if (!/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/.test(value)) {
            note.textContent = _('Введите MAC-адрес в формате aa:bb:cc:dd:ee:ff.');
            return;
        }
        if (!devices.has(value)) devices.set(value, {mac:value});
        selected.add(value);
        mac.value = '';
        note.textContent = '';
        renderDevices();
    }

    mac.addEventListener('keydown', function(event) {
        if (event.key === 'Enter') { event.preventDefault(); addDevice(); }
    });
    renderDevices();
    return owsUI.form([
        E('fieldset', {}, [E('legend', {}, _('Домены')),
            E('p', {}, _('Один домен в строке. Правила включают поддомены. При одинаковой записи приоритет у чёрного списка.')),
            E('div', {class:'ows-fields'}, [allow.field, block.field])]),
        E('fieldset', {}, [E('legend', {}, _('Устройства без блокировки')),
            E('p', {}, _('Выбранные устройства получают DNS без блокировки рекламы. IP-списки в файрволе действуют для всех устройств.')),
            list, E('div', {class:'ows-actions'}, [mac, owsUI.button(_('Добавить MAC'), addDevice)]), note])
    ], _('Сохранить исключения'), function() {
        if (selected.size > 64) { note.textContent = _('Можно выбрать до 64 устройств.'); return; }
        return submit('edit', JSON.stringify({revision:data.revision,allow:allow.input.value,block:block.input.value,devices:Array.from(selected)}));
    });
}

function migrationPanel(followJob) {
    var report = E('div', {role:'status'});
    var feedback = owsUI.feedback();
    var prepare = E('button', {type:'button',class:'cbi-button',hidden:''}, _('Собрать черновик'));
    var verify = E('button', {type:'button',class:'cbi-button',hidden:''}, _('Сверить с роутером'));
    var refresh = E('button', {type:'button',class:'cbi-button',hidden:''}, _('Обновить списки в черновике'));
    var schedule = E('button', {type:'button',class:'cbi-button',hidden:''}, _('Проверить перенос расписания'));
    var takeover = E('button', {type:'button',class:'cbi-button',hidden:''}, _('Передать управление OWS'));
    var enableLight = E('button', {type:'button',class:'cbi-button',hidden:''}, _('Установить HaGeZi Light'));
    var liveRefresh = E('button', {type:'button',class:'cbi-button',disabled:''}, _('Обновить сейчас'));
    var auto = E('input', {type:'checkbox'});
    var updateStatus = E('p');
    var updates = E('fieldset', {hidden:''}, [E('legend', {}, _('Обновление списков')),
        E('label', {}, [auto, ' ', _('Автообновление')]), updateStatus, liveRefresh]);
    var toggle = E('button', {type:'button',class:'cbi-button',disabled:'',hidden:''});
    var save = E('button', {type:'button',class:'cbi-button',disabled:''}, _('Применить выбор списков'));
    var profile = E('select', {class:'cbi-input-select'}, [
        ['light','Light'], ['multi','Multi'], ['pro','Pro'], ['proplus','Pro++'], ['ultimate','Ultimate']
    ].map(function(item) { return E('option', {value:item[0]}, item[1]); }));
    var sources = [];
    var sourceControls = E('div');
    var exceptions = E('fieldset', {hidden:''});
    var settings = E('fieldset', {hidden:''}, [
        E('legend', {}, _('Что блокировать')),
        owsUI.field(_('Доменный профиль HaGeZi'), profile),
        sourceControls,
        E('div', {class:'ows-actions'}, save)
    ]);
    var selected = '', paused = false;
    var busy = false;

    function choice() {
        return profile.value + ':' + sources.reduce(function(mask, item) { return mask | (item.input.checked ? item.bit : 0); }, 0);
    }

    function changeSelection() { save.disabled = busy || settings.disabled || choice() === selected; }

    function renderSources(data, mask) {
        sources = data.tachyon.map(function(item) {
            var input = E('input', {type:'checkbox'});
            input.checked = !!(mask & item.bit);
            input.addEventListener('change', changeSelection);
            return {bit:item.bit,kind:item.kind,input:input,label:item.label,description:item.description};
        });
        function group(kind, label) {
            return E('fieldset', {}, [E('legend', {}, label)].concat(sources.filter(function(item) {
                return item.kind === kind;
            }).map(function(item) {
                return E('div', {}, [E('label', {}, [item.input, ' ', item.label]), ' · ', item.description]);
            })));
        }
        sourceControls.replaceChildren(E('h4', {}, 'Tachyon Lists'),
            group('dns', _('Домены · DNS')), group('ip', _('IP-адреса · файрвол')));
    }

    function load() {
        return draftStatus().then(owsUI.checked).then(function(data) {
            var managed = data.owner === 'ows';
            paused = !!data.paused;
            settings.hidden = exceptions.hidden = updates.hidden = !managed || !data.settings;
            toggle.hidden = !managed;
            settings.disabled = exceptions.disabled = busy || paused || data.fast_enabled || !data.active_profile;
            toggle.textContent = paused ? _('Включить фильтрацию OWS') : _('Приостановить фильтрацию OWS');
            toggle.disabled = busy || (paused && data.fast_enabled);
            if (managed && data.active_profile && data.settings) {
                profile.value = data.active_profile;
                renderSources(data.settings, data.ip_mask);
                exceptions.replaceChildren(E('legend', {}, _('Исключения и свои правила')), adblockExceptions(data.settings, submit));
                auto.checked = data.settings.auto_update;
                auto.disabled = busy;
                var daily = /^(\d+) (\d+) \* \* \*$/.exec(data.settings.schedule_time);
                var when = daily ? daily[2].padStart(2, '0') + ':' + daily[1].padStart(2, '0') : data.settings.schedule_time;
                updateStatus.textContent = [_('Последнее обновление'), timestamp(data.settings.updated),
                    auto.checked && when ? _('По расписанию') + ' ' + when : ''].filter(Boolean).join(' · ');
                selected = choice();
            }
            changeSelection();
            verify.disabled = busy || !data.prepared;
            prepare.hidden = verify.hidden = refresh.hidden = schedule.hidden = takeover.hidden = managed || !data.legacy;
            enableLight.hidden = managed || !data.light_start;
            enableLight.disabled = busy;
            liveRefresh.disabled = busy || !managed || paused || data.fast_enabled;
            refresh.disabled = schedule.disabled = busy || managed || !data.prepared || !data.matches;
            takeover.disabled = busy || managed || !data.matches || !data.update || !data.schedule;
            if (data.light_start) {
                report.replaceChildren(E('dl', {}, owsUI.details([
                    [_('Пресет для установки'), 'HaGeZi Light'],
                    [_('Фильтрация'), _('Выключена')],
                    [_('Tachyon Lists'), _('Не выбраны')],
                    [_('Автообновление'), _('Выключено')]
                ])), E('p', {}, _('Light использует только доменный список. Для установки требуется 48 МиБ доступной RAM.')));
                return;
            }
            if (data.fast_enabled && !managed) {
                report.textContent = _('Сначала отключите AdBlock Fast, чтобы установить фильтрацию OWS.');
                return;
            }
            if (!data.prepared) {
                report.textContent = _('Черновик ещё не собран.');
                return;
            }
            if (managed) {
                report.textContent = paused ? (data.fast_enabled ? _('Фильтрация OWS приостановлена. Работает AdBlock Fast.') :
                    _('Фильтрация OWS приостановлена.')) : data.light_dns_only ?
                    _('OWS · Light через dnsmasq · требуется 48 МиБ доступной RAM для обновления') : _('Блокировкой управляет OWS.');
                return;
            }
            report.replaceChildren(E('strong', {},
                data.matches ? _('Снимок совпадал при последней проверке') : _('Снимок устарел')),
                E('dl', {}, [
                    E('dt', {}, _('Проверено')), E('dd', {}, timestamp(data.checked)),
                    E('dt', {}, _('Профиль Zapret-Manager')), E('dd', {}, data.profile || '—'),
                    E('dt', {}, _('Файлы / IP-списки / задания')), E('dd', {}, [data.files, data.ip_lists, data.jobs].join(' / ')),
                    E('dt', {}, _('Синтаксис DNS-конфига')), E('dd', {}, data.dns_syntax ? _('Проверен') : '—'),
                    E('dt', {}, _('Кандидат обновления')), E('dd', {}, data.update ?
                        data.update.domains + ' / ' + data.update.ip_lists + ' · ' + timestamp(data.update.checked) : '—'),
                    E('dt', {}, _('Копия расписания')), E('dd', {}, data.schedule ?
                        data.schedule.time + ' · ' + timestamp(data.schedule.checked) : '—'),
                    E('dt', {}, _('Таблицы nftables в снимке')), E('dd', {}, [
                        data.device_table ? _('исключения устройств') : '', data.ip_table ? _('IP-блокировка') : ''
                    ].filter(Boolean).join(', ') || '—')
                ]));
        }).catch(function(error) {
            prepare.hidden = verify.hidden = refresh.hidden = schedule.hidden = takeover.hidden = enableLight.hidden = true;
            report.textContent = error.message || _('Не удалось прочитать состояние фильтрации');
        });
    }

    function submit(action, change) {
        if (busy) return;
        busy = prepare.disabled = verify.disabled = refresh.disabled = schedule.disabled = takeover.disabled = liveRefresh.disabled = toggle.disabled = settings.disabled = true;
        exceptions.disabled = auto.disabled = enableLight.disabled = true;
        feedback.start(_('Ставим операцию в очередь…'));
        return owsUI.job(draftAction(action, change || ''), followJob, true).then(function(result) {
            owsUI.showResult(feedback, result, _('Операция не завершилась успешно'));
        }).catch(function(error) { feedback.show(error.message); })
            .finally(function() { busy = prepare.disabled = false; return load(); });
    }

    prepare.addEventListener('click', function() { submit('prepare'); });
    verify.addEventListener('click', function() { submit('check'); });
    refresh.addEventListener('click', function() { submit('refresh'); });
    schedule.addEventListener('click', function() { submit('schedule-plan'); });
    takeover.addEventListener('click', function() {
        if (window.confirm(_('Передать расписание в OWS и применить проверенные списки? dnsmasq будет перезапущен.'))) submit('takeover');
    });
    enableLight.addEventListener('click', function() {
        if (window.confirm(_('Скачать список HaGeZi Light и включить DNS-фильтрацию? dnsmasq будет перезапущен.'))) submit('enable-light');
    });
    liveRefresh.addEventListener('click', function() { submit('refresh-live'); });
    auto.addEventListener('change', function() { submit(auto.checked ? 'schedule:on' : 'schedule:off'); });
    toggle.addEventListener('click', function() {
        if (window.confirm(_('Применить изменение? dnsmasq будет перезапущен.'))) submit(paused ? 'resume' : 'pause');
    });
    profile.addEventListener('change', changeSelection);
    save.addEventListener('click', function() {
        if (window.confirm(_('Скачать выбранные списки и применить их после проверки?'))) submit('configure:' + choice());
    });
    return {load:load, content:E('section', {}, [report,
        E('div', {class:'ows-actions'}, [enableLight, prepare, verify, refresh, schedule, takeover, toggle]), settings, exceptions, updates, feedback.content])};
}

return baseclass.extend({
    tab: function(followJob) {
        var summary = E('dl', {});

        function load() {
            function state(value) { return value ? _('Активно') : _('Не обнаружено'); }
            return info().then(function(data) {
                summary.replaceChildren(
                    E('dt', {}, 'dnsmasq'),E('dd', {}, state(data.dnsmasq)),
                    E('dt', {}, _('DNS-watchdog NetShift')),E('dd', {}, state(data.watchdog)),
                    E('dt', {}, _('Список AdBlock Fast')),E('dd', {}, state(data.adblock)),
                    E('dt', {}, _('Обновление списка')),E('dd', {}, timestamp(data.last_update)),
                    data.network && data.network.dns === 'isp' ? E('dt', {}, _('DNS провайдера для .ru, .su, .рф')) : '',
                    data.network && data.network.dns === 'isp' ? E('dd', {}, data.network.resolvers || '—') : ''
                );
            }).catch(function() { summary.textContent = _('Не удалось прочитать состояние DNS'); });
        }

        return {id:'dns',label:_('DNS'),activate:load,content:E('div', {}, [summary,checkForm(followJob, load)])};
    },

    adblockTab: function(entry, context, options) {
        var summary = E('p', {role:'status'});
        var migration = migrationPanel(context.followJob);
        var native = options ? nativeView.tab(Object.assign({id:'adblock-fast-settings'}, options)) : null;
        var open = E('button', {type:'button',class:'cbi-button',hidden:''}, _('Открыть настройки AdBlock Fast'));
        var feedback = owsUI.feedback();
        var install = owsUI.button(_('Установить'), installFast);
        var busy = false;
        install.hidden = true;
        var domain = E('input', {type:'text',class:'cbi-input-text',maxlength:254,placeholder:'example.org',required:''});
        if (native) open.addEventListener('click', native.activate);

        function installFast() {
            if (busy || !window.confirm(_('Установить AdBlock Fast из репозитория OpenWrt? Пакет может запустить фильтрацию.'))) return;
            busy = install.disabled = true;
            feedback.start(_('Ставим установку в очередь…'));
            return owsUI.job(draftAction('install-fast', ''), context.followJob, true).then(function(result) {
                owsUI.showResult(feedback, result);
            }).catch(function(error) { feedback.show(error.message); }).finally(function() {
                busy = false;
                return loadFast();
            });
        }

        function loadFast() {
            return Promise.all([info().then(owsUI.checked), draftStatus().catch(function() { return {}; })]).then(function(results) {
                var data = results[0], status = results[1];
                var conflict = status.owner === 'ows' ? !status.paused : data.legacy_adblock;
                var available = !!native && data.adblock_ui && !conflict;
                open.hidden = !available;
                if (native) native.content.hidden = !available;
                install.hidden = data.adblock_installed && data.adblock_ui;
                install.disabled = busy || conflict;
                install.textContent = data.adblock_installed ? _('Установить интерфейс LuCI') : _('Установить AdBlock Fast');
                summary.textContent = conflict ? (status.owner === 'ows' ?
                    _('Сначала приостановите фильтрацию OWS во вкладке dnsmasq + nftables.') :
                    _('Сначала отключите действующую блокировку в Zapret-Manager.')) :
                    !data.adblock_installed ? _('Пакет AdBlock Fast не установлен.') :
                    data.adblock_fast_enabled ? _('AdBlock Fast включён.') : _('AdBlock Fast установлен и выключен.');
            }).catch(function() { summary.textContent = _('Не удалось прочитать состояние AdBlock Fast'); });
        }

        var tabs = context.createTabs(_('Режимы блокировки рекламы'), [
            {id:'adblock-ows-mode', label:'dnsmasq + nftables', activate:migration.load, content:E('div', {}, [
                migration.content,
                E('p', {}, [external(_('Каталог доменных списков HaGeZi'), 'https://github.com/hagezi/dns-blocklists'),
                    ' · ', external(_('Каталог Tachyon Lists'), 'https://github.com/Dushnilin/tachyon-lists')])
            ])},
            {id:'adblock-fast-mode', label:'AdBlock Fast', activate:loadFast, content:E('div', {}, [
                summary, E('p', {}, external(_('Документация AdBlock Fast'), 'https://docs.mossdef.org/adblock-fast/')),
                E('div', {class:'ows-actions'}, [install, open]), feedback.content, native ? native.content : ''
            ])}
        ]);
        return {
            id:'module-' + entry.id, label:entry.name, activate:migration.load,
            openSection:function(list) { tabs.selectId(list === 'adblock-fast' ? 'adblock-fast-mode' : 'adblock-ows-mode'); },
            content:E('div', {}, [tabs.content,
                E('p', {}, _('Проверка запрашивает запись A через DNS роутера. Правила для отдельных устройств могут давать другой результат.')),
                checkForm(context.followJob, function() {}, domain)
            ])
        };
    }
});
