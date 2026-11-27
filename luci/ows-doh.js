'use strict';
'require baseclass';
'require rpc';
'require view.ows-ui as owsUI';

var info = rpc.declare({object:'ows', method:'doh_info'});
var action = rpc.declare({object:'ows', method:'doh_action', params:['action']});

var profileTypes = {
    plain: [_('Без фильтрации'), _('Обычное разрешение имён по HTTPS без фильтра категорий.')],
    safe: [_('Защита от угроз'), _('Фильтрует домены, связанные с фишингом и вредоносным ПО.')],
    family: [_('Семейный фильтр'), _('Фильтрует угрозы и сайты для взрослых.')],
    geo: [_('Обход геоблокировок'), _('Профиль для доступа к отдельным регионально ограниченным сервисам.')],
    geo_eu: [_('Европа'), _('Европейский сервер GeoHide для регионально ограниченных сервисов.')],
    geo_us: [_('США'), _('Американский сервер GeoHide для регионально ограниченных сервисов.')]
};

function policySlot(label, profiles, families, selected, optional) {
    var publicOptions = E('optgroup', {label:_('Публичные резолверы')});
    var geoOptions = E('optgroup', {label:_('С обходом геоблокировок')});
    families.forEach(function(group, id) {
        var options = group[0].kind.indexOf('geo') === 0 ? geoOptions : publicOptions;
        options.appendChild(E('option', {value:id}, group[0].label));
    });
    var choices = [publicOptions, geoOptions];
    choices.unshift(E('option', {value:''}, optional ? _('Без резерва') : _('Выберите провайдера')));
    var provider = E('select', {class:'cbi-input-select'}, choices);
    var variant = E('select', {class:'cbi-input-select'});
    var notes = E('p');

    function describe() {
        var profile = profiles.get(variant.value);
        notes.replaceChildren();
        if (profile) {
            notes.appendChild(document.createTextNode(profile.description || profileTypes[profile.kind][1]));
            notes.appendChild(E('br'));
            notes.appendChild(E('small', {}, profile.url));
        }
    }

    function chooseVariant(id) {
        var group = families.get(provider.value) || [];
        var options = group.map(function(profile) {
            return E('option', {value:profile.id}, profileTypes[profile.kind][0]);
        });
        if (!options.length) options.push(E('option', {value:''}, '—'));
        variant.replaceChildren.apply(variant, options);
        variant.value = id || (group.length ? group[0].id : '');
        variant.disabled = group.length < 2;
        describe();
    }

    if (selected) provider.value = selected.family;
    else provider.value = '';
    chooseVariant(selected ? selected.id : '');
    provider.addEventListener('change', function() { chooseVariant(''); });
    variant.addEventListener('change', describe);
    return {
        content: E('div', {}, [owsUI.field(label, provider), owsUI.field(_('Профиль'), variant), notes]),
        value: function() { return variant.value; }
    };
}

return baseclass.extend({
    tab: function(followJob) {
        var summary = E('dl');
        var resolvers = E('div');
        var policy = E('fieldset', {class:'cbi-section', hidden:''});
        var feedback = owsUI.feedback();
        var controls = E('div', {class:'ows-actions'});
        var busy = false;
        var state;

        function renderActions() {
            var managed = state && state.owner === 'ows';
            var migration = state && state.owner === 'zapret-manager' && state.installed;
            var complete = state && state.installed && !state.limited;
            policy.disabled = busy || !state || !(state.can_initialize || (managed && state.guard));
            controls.replaceChildren(
                owsUI.button(_('Обновить состояние'), load, busy),
                state && (!state.installed || !state.native) ? owsUI.button(state.installed ? _('Установить интерфейс LuCI') : _('Установить DoH'), function() {
                    if (window.confirm(_('Установить HTTPS DNS Proxy из репозитория OpenWrt?')))
                        submit('install');
                }, busy) : '',
                state && state.native && !managed ? E('a', {href:L.url('admin','services','https-dns-proxy')}, _('Настройки HTTPS DNS Proxy')) : '',
                complete ? owsUI.button(_('Проверить DNS'), function() { submit('check'); }, busy) : '',
                managed ? owsUI.button(_('Проверить переключение'), function() {
                    if (window.confirm(_('Временно переключить DoH на резерв и вернуться на основной сервер?'))) submit('test-switch');
                }, busy || !state.guard) : '',
                managed && state.standalone_setup ? owsUI.button(state.failover ? _('Выключить автопереключение') : _('Включить автопереключение'), function() {
                    submit(state.failover ? 'auto:off' : 'auto:on');
                }, busy || !state.guard) : '',
                migration ? owsUI.button(_('Собрать черновик'), function() { submit('prepare'); }, busy) : '',
                migration ? owsUI.button(_('Сверить черновик'), function() { submit('verify'); }, busy || !state.migration.prepared) : '',
                migration ? owsUI.button(_('Передать резервирование OWS'), function() {
                    if (window.confirm(_('Проверить резервные серверы и передать watchdog OWS?'))) submit('takeover');
                }, busy || !state.migration.matches) : ''
            );
        }

        function renderPolicy(data, profiles) {
            var initialize = data.can_initialize;
            policy.hidden = !data.available_providers.length || !(initialize || (data.owner === 'ows' && data.providers.length));
            if (policy.hidden) return;
            var labels = [_('Основной провайдер'), _('Первый резерв'), _('Второй резерв'), _('Третий резерв')];
            var families = new Map();
            profiles.forEach(function(profile) {
                if (!families.has(profile.family)) families.set(profile.family, []);
                families.get(profile.family).push(profile);
            });
            var slots = labels.map(function(label, index) {
                return policySlot(label, profiles, families, profiles.get(data.providers[index]), index > 1);
            });
            policy.replaceChildren(
                E('legend', {}, _('Цепочка переключения')),
                E('p', {}, _('Выберите провайдера и профиль для каждого места в цепочке. Резервы проверяются по порядку.')),
                owsUI.form([E('div', {class:'ows-fields'}, slots.map(function(slot) { return slot.content; }))],
                    initialize ? _('Проверить и запустить DoH') : _('Сохранить цепочку'), function() {
                    var selected = slots.map(function(slot) { return slot.value(); });
                    var order = selected.filter(Boolean);
                    if (!selected[0] || !selected[1] || new Set(order).size !== order.length) {
                        feedback.show(_('Выберите основной профиль и от одного до трёх резервных без повторов.'));
                        return;
                    }
                    if (initialize) {
                        if (window.confirm(_('Запустить DoH и направить запросы dnsmasq на выбранный основной сервер?')))
                            return submit('initialize:' + order.join(','));
                        return;
                    }
                    return submit('configure:' + data.providers.join(',') + ':' + order.join(','));
                })
            );
        }

        function load() {
            return info().then(owsUI.checked).then(function(data) {
                function enabled(value) { return value ? _('Включено') : _('Выключено'); }
                state = data;
                if (!data.installed || data.limited) {
                    policy.hidden = true;
                    resolvers.replaceChildren();
                    summary.replaceChildren.apply(summary, owsUI.details([
                        [_('Служба'), data.installed ? _('Пакет установлен') : _('Пакет не установлен')],
                        [_('Диагностика DoH'), data.limited ? _('Для подробного состояния установите jq.') : '']
                    ]));
                    return;
                }
                var draft = data.migration;
                var mark = draft.prepared ? (draft.matches ? _('Совпал при последней проверке') : _('Устарел')) : _('Не собран');
                var profiles = new Map(data.available_providers.map(function(profile) { return [profile.id, profile]; }));
                function providerName(id) {
                    var profile = profiles.get(id);
                    return profile ? profile.label + ' · ' + profileTypes[profile.kind][0] : id;
                }
                summary.replaceChildren.apply(summary, owsUI.details([
                    [_('Служба'), !data.installed ? _('Пакет не установлен') : data.running ? _('Работает') : _('Остановлена')],
                    [_('Upstream dnsmasq'), data.upstreams.join(', ')],
                    [_('Перехват DNS'), enabled(data.force_dns)],
                    [_('Автопереключение'), data.owner === 'ows' && !data.guard ? _('Приостановлено') : enabled(data.failover)],
                    [_('Владелец watchdog'), data.owner === 'ows' ? (data.guard ? 'OWS' : _('OWS · проверьте скрипты и расписание Zapret-Manager')) :
                        data.owner === 'zapret-manager' ? 'Zapret-Manager' : _('Не настроен')],
                    [_('Активный провайдер'), providerName(data.active)],
                    [_('Цепочка провайдеров'), data.providers.map(providerName).join(' → ')],
                    [_('Обычный DNS при сбое'), enabled(data.direct_fallback)],
                    [_('Задания Zapret-Manager'), data.owner === 'zapret-manager' ? data.legacy_jobs : ''],
                    [_('Черновик'), data.owner === 'zapret-manager' ? mark + (draft.prepared ? ' · ' + draft.files + ' ' + _('файлов') : '') : '']
                ]));
                resolvers.replaceChildren(!data.can_initialize && data.resolvers.length ? owsUI.table([_('Сервер DoH'), _('Локальный адрес'), _('Порт')],
                    data.resolvers.map(function(item) { return [item.host, item.listen === 'other' ? '—' : item.listen, String(item.port || '—')]; })) : '');
                renderPolicy(data, profiles);
            }).catch(function() {
                state = null;
                policy.hidden = true;
                summary.textContent = _('Не удалось прочитать состояние DoH');
            }).finally(renderActions);
        }

        function submit(name) {
            if (busy) return;
            busy = true;
            renderActions();
            feedback.start(_('Ставим операцию в очередь…'));
            return owsUI.job(action(name), followJob, true).then(function(result) {
                owsUI.showResult(feedback, result);
            }).catch(function(error) { feedback.show(error.message); })
                .finally(function() { busy = false; return load(); });
        }

        renderActions();
        return {id:'doh',label:'DoH',activate:load,content:E('div', {}, [summary,policy,resolvers,controls,feedback.content])};
    }
});
