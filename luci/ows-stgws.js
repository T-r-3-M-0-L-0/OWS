'use strict';
'require baseclass';
'require rpc';
'require view.ows-ui as owsUI';

var info = rpc.declare({ object: 'ows', method: 'stgws_info' });
var execute = rpc.declare({ object: 'ows', method: 'stgws_action', params: ['action'] });

return baseclass.extend({
    tab: function(entry, createTabs, follow) {
        var service = E('div');
        var routes = E('div');
        var automation = E('div');
        var packages = E('div');
        var feedback = owsUI.feedback();
        var busy = false;
        var refresh = E('button', { type: 'button', class: 'cbi-button' }, _('Обновить'));

        var button = owsUI.button;

        function submit(action, confirmText) {
            if (busy || (confirmText && !window.confirm(confirmText))) return;
            busy = true;
            feedback.start(_('Ставим операцию в очередь'));
            return owsUI.job(execute(action), follow, true).then(function(result) {
                owsUI.showResult(feedback, result);
                return load();
            }).catch(function(error) {
                feedback.show(error.message || _('Запрос отклонён. Проверьте права управления sTGWS.'));
            }).finally(function() { busy = false; });
        }

        function action(label, name, disabled, confirmText) {
            return button(label, function() { submit(name, confirmText); }, disabled);
        }

        function render(data) {
            var installed = data.installed;
            service.replaceChildren(
                E('p', {}, !installed ? _('Служба не установлена') : data.running ? _('Мост запущен') : _('Мост остановлен')),
                E('dl', {}, owsUI.details([
                    [_('Версия пакета'), data.version], [_('Основной домен'), data.domain],
                    [_('Запуск при загрузке'), data.enabled ? _('Включён') : _('Выключен')]
                ])),
                E('div', { class: 'ows-actions' }, action(_('Перезапустить'), 'restart', !installed,
                    _('Перезапустить sTGWS? Активные соединения переподключатся.')))
            );
            var rows = (data.routes || []).map(function(route) {
                return [route.dc, route.mode, route.front || '—'];
            });
            routes.replaceChildren(
                rows.length ? owsUI.table([_('ДЦ'), _('Режим'), _('Фронт')], rows) : E('p', {}, _('Карта маршрутов пуста')),
                E('div', { class: 'ows-actions' }, [
                    action(_('Проверить MTProto'), 'check', !installed),
                    action(_('Подобрать домен'), 'reconfigure', !installed, _('Запустить подбор домена sTGWS?')),
                    action(_('Умная карта'), 'route_smart', !installed, _('Проверить альтернативы и применить прошедшую проверку карту?')),
                    action(_('Сохранить карту'), 'route_save', !installed),
                    action(_('Восстановить карту'), 'route_restore', !installed || !data.saved, _('Применить сохранённую карту после проверки?')),
                    action(data.smart ? _('Авто-карта включена') : _('Авто-карта выключена'), data.smart ? 'route_auto_off' : 'route_auto_on', !installed)
                ])
            );

            var schedule = E('select', { class: 'cbi-input-select', id: 'ows-stgws-schedule' },
                ['off', 'h1', 'h2', 'h3', 'h6', 'h12'].map(function(value) {
                    return E('option', { value: value }, value === 'off' ? _('Выключен') : _('Каждые %s ч').format(value.slice(1)));
                }));
            schedule.value = data.schedule || 'off';
            automation.replaceChildren(
                fieldForSchedule(schedule),
                E('div', { class: 'ows-actions' }, [
                    button(_('Сохранить расписание'), function() { submit('schedule_' + schedule.value); }, !installed),
                    action(data.watch === 'on' ? _('Отключить восстановление процесса') : _('Включить восстановление процесса'),
                        data.watch === 'on' ? 'watch_off' : 'watch_on', !installed)
                ])
            );
            packages.replaceChildren(
                E('p', {}, data.available ? _('Версии в репозиториях') + ' · ' + data.available
                    : _('Пакет tgws пока не найден в локальном индексе.')),
                !installed ? E('p', {}, _('OWS скачает пакет sTGWS для архитектуры роутера в формате APK или IPK.')) : '',
                E('div', { class: 'ows-actions' }, [
                    action(_('Установить sTGWS'), 'install', installed || !data.manager, _('Установить sTGWS и запустить службу?')),
                    action(_('Обновить'), 'update', !installed || !data.available, _('Обновить пакет tgws?')),
                    action(_('Переустановить'), 'reinstall', !installed || !data.available, _('Переустановить пакет tgws?')),
                    action(_('Удалить пакет'), 'remove', !installed || !data.manager, _('Удалить пакет tgws? Мост перестанет обслуживать соединения.'))
                ])
            );
        }

        function fieldForSchedule(schedule) {
            return E('div', { class: 'ows-field' }, [
                E('label', { for: 'ows-stgws-schedule' }, _('Интервал перезапуска')), schedule
            ]);
        }

        function load() {
            refresh.disabled = true;
            return info().then(function(data) {
                if (data.error) feedback.show(data.error);
                else render(data);
            }, function() {
                feedback.show(_('Не удалось прочитать состояние sTGWS'));
            }).finally(function() { refresh.disabled = false; });
        }

        refresh.addEventListener('click', load);
        var tabs = createTabs(_('Разделы sTGWS'), [
            { id: 'stgws-service', label: _('Служба'), content: service },
            { id: 'stgws-routes', label: _('Маршруты'), content: routes },
            { id: 'stgws-auto', label: _('Автоматизация'), content: automation },
            { id: 'stgws-package', label: _('Пакет'), content: packages }
        ], entry.installed === false ? 'stgws-package' : 'stgws-service');
        return {
            id: 'module-stgws', label: entry.name, activate: load,
            content: [
                E('div', { class: 'ows-module-heading' }, [E('h3', {}, entry.name), refresh]),
                tabs.content, feedback.content
            ]
        };
    }
});
