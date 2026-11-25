'use strict';
'require baseclass';
'require view.ows-native as nativeView';
'require view.ows-service as serviceView';
'require view.ows-stgws as stgws';
'require view.ows-vpn-panel as vpn';

function vpnTab(entry, context, template) {
    return vpn.tab(entry, context.createTabs, context.followJob, template);
}

var defaults = {
    netshift: {
        service: 'netshift',
        renderStatus: function(data, actions) {
            return [
                E('p', {}, !data.installed ? _('NetShift не установлен') : data.running ?
                    _('sing-box запущен, таблица NetShiftTable загружена') : _('NetShift не активен')),
                E('p', {}, [_('Версия пакета'), ' · ', data.version || '—']),
                actions.canDiagnose ? actions.button(_('Проверить состояние'), 'diagnose', true) : ''
            ];
        },
        native: {
            route: 'netshift',
            acl: 'luci-app-netshift',
            visible: function(state) { return state.ui && state.ui.native; }
        },
        jobName: 'NetShift',
        jobActions: { diag: _('Диагностика') }
    },
    'tg-ws-proxy': {
        service: 'tg-ws-proxy',
        proxy: true,
        tab: function(entry, context, template) { return serviceView.tab(entry, context.followJob, template); },
        statusMethod: 'tg_proxy_info',
        actionMethod: 'tg_proxy_action',
        readError: _('Не удалось прочитать состояние прокси'),
        fields: [
            { label: _('Служба'), value: function(data) {
                return !data.installed ? _('Служба не установлена') : data.running ? _('Прокси работает') : _('Прокси остановлен');
            } },
            { label: _('Пакет'), value: function(data) { return data.version; } },
            { label: _('TCP-порт'), value: function(data) { return data.port; } },
            { label: _('Автозапуск'), value: function(data) { return data.enabled ? _('Включён') : _('Выключен'); } }
        ],
        actions: [
            { id: 'start', label: _('Запустить'), enabled: function(data) { return !data.running; } },
            { id: 'restart', label: _('Перезапустить'), enabled: function(data) { return data.running; } },
            { id: 'stop', label: _('Остановить'), enabled: function(data) { return data.running; } }
        ],
        jobName: _('Telegram-прокси'),
        jobActions: { check: _('Проверка состояния'), start: _('Запуск'), restart: _('Перезапуск'), stop: _('Остановка') }
    },
    'adblock-fast': {
        service: 'adblock-fast',
        native: { route: 'adblock-fast', acl: 'luci-app-adblock-fast' },
        tab: function(entry, context, template) {
            if (!template.native) return null;
            var native = nativeView.tab(Object.assign({}, template.native, { id: 'module-' + entry.id }));
            native.label = entry.name;
            return native;
        }
    },
    stgws: {
        service: 'tgws',
        proxy: true,
        tab: function(entry, context) { return stgws.tab(entry, context.createTabs, context.followJob); }
    }
};

function matched(templates, entry) {
    if (!templates || !Object.prototype.hasOwnProperty.call(templates, entry.id)) return null;
    var template = templates[entry.id];
    return template && template.service === entry.service ? template : null;
}

return baseclass.extend({
    load: function() {
        var self = this;
        return L.require('view.ows-template-overrides').then(function(overrides) {
            self.overrides = overrides;
            return null;
        }, function() {
            self.overrides = null;
            return _('Не удалось загрузить локальные шаблоны OWS. Используются штатные.');
        });
    },

    proxyGroup: function() {
        return Object.assign({ label: _('Прокси'), sectionsLabel: _('Модули прокси'),
            empty: _('Добавьте адаптер прокси через «Обзор».') }, this.overrides && this.overrides.proxyGroup);
    },

    panel: function(tab) {
        var local = this.overrides && this.overrides.panels;
        if (!local || !Object.prototype.hasOwnProperty.call(local, tab.id)) return tab;
        var override = local[tab.id];
        return Object.assign({}, tab, typeof override === 'function' ? override(tab) : override, { id: tab.id });
    },

    resolve: function(entry, drivers) {
        var isVPN = vpn.supports(entry, drivers);
        var standard = matched(defaults, entry);
        var override = matched(this.overrides && this.overrides.modules, entry);
        var template = Object.assign({ proxy: isVPN || entry.category === 'proxy', tab: isVPN ? vpnTab : null }, standard, override);
        if (standard && standard.native && override && override.native) {
            template.native = Object.assign({}, standard.native, override.native);
        }
        if (standard && standard.jobActions && override && override.jobActions) {
            template.jobActions = Object.assign({}, standard.jobActions, override.jobActions);
        }
        return template;
    }
});
