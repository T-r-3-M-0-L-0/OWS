'use strict';
'require baseclass';
'require rpc';

var info = rpc.declare({ object: 'ows', method: 'stgws_info' });
var execute = rpc.declare({ object: 'ows', method: 'stgws_action', params: ['action'] });
var output = rpc.declare({ object: 'ows', method: 'job_output', params: ['job'] });

return baseclass.extend({
    tab: function(entry, createTabs, follow) {
        var service = E('div');
        var routes = E('div');
        var automation = E('div');
        var packages = E('div');
        var notice = E('p', { 'aria-live': 'polite' });
        var log = E('pre', { hidden: '' });
        var current = '';
        var refresh = E('button', { type: 'button', class: 'cbi-button' }, _('Обновить'));

        function button(label, handler, disabled) {
            var element = E('button', { class: 'cbi-button', type: 'button' }, label);
            element.disabled = !!disabled;
            element.addEventListener('click', handler);
            return element;
        }

        function submit(action, confirmText) {
            if (current || (confirmText && !window.confirm(confirmText))) return;
            current = 'submitting';
            notice.textContent = _('Ставим операцию в очередь');
            log.hidden = true;
            execute(action).then(function(result) {
                notice.textContent = result.error || '';
                if (!result.job) { current = ''; return; }
                current = result.job;
                follow(result.job, function(state) {
                    if (current !== state.job || ['queued', 'applying'].indexOf(state.phase) >= 0) return;
                    current = '';
                    notice.textContent = state.phase === 'done' ? _('Операция завершена') : _('Операция завершилась с ошибкой');
                    output(state.job).then(function(result) {
                        if (current) return;
                        log.textContent = result.output || '';
                        log.hidden = !log.textContent;
                    }, function() {
                        notice.textContent = _('Не удалось прочитать журнал операции');
                    });
                    load();
                });
            }, function() {
                current = '';
                notice.textContent = _('Запрос отклонён. Проверьте права управления sTGWS.');
            });
        }

        function action(label, name, disabled, confirmText) {
            return button(label, function() { submit(name, confirmText); }, disabled);
        }

        function render(data) {
            var installed = data.installed;
            service.replaceChildren(
                E('p', {}, !installed ? _('Служба не установлена') : data.running ? _('Мост запущен') : _('Мост остановлен')),
                E('dl', {}, [
                    E('dt', {}, _('Версия пакета')), E('dd', {}, data.version || '—'),
                    E('dt', {}, _('Основной домен')), E('dd', {}, data.domain || '—'),
                    E('dt', {}, _('Запуск при загрузке')), E('dd', {}, data.enabled ? _('Включён') : _('Выключен'))
                ]),
                E('div', { class: 'ows-actions' }, action(_('Перезапустить'), 'restart', !installed,
                    _('Перезапустить sTGWS? Активные соединения переподключатся.')))
            );
            var rows = (data.routes || []).map(function(route) {
                return E('tr', { class: 'tr' }, [
                    E('td', { class: 'td' }, route.dc),
                    E('td', { class: 'td' }, route.mode),
                    E('td', { class: 'td' }, route.front || '—')
                ]);
            });
            routes.replaceChildren(
                rows.length ? E('table', { class: 'table' }, [
                    E('thead', {}, E('tr', { class: 'tr table-titles' }, [_('ДЦ'), _('Режим'), _('Фронт')].map(function(text) {
                        return E('th', { class: 'th', scope: 'col' }, text);
                    }))), E('tbody', {}, rows)
                ]) : E('p', {}, _('Карта маршрутов пуста')),
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
                    : _('В настроенных репозиториях нет пакета tgws')),
                E('div', { class: 'ows-actions' }, [
                    action(_('Установить'), 'install', installed || !data.available, _('Установить tgws из настроенного репозитория?')),
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
                if (data.error) notice.textContent = data.error;
                else render(data);
            }, function() {
                notice.textContent = _('Не удалось прочитать состояние sTGWS');
            }).finally(function() { refresh.disabled = false; });
        }

        refresh.addEventListener('click', load);
        var tabs = createTabs(_('Разделы sTGWS'), [
            { id: 'stgws-service', label: _('Служба'), content: service },
            { id: 'stgws-routes', label: _('Маршруты'), content: routes },
            { id: 'stgws-auto', label: _('Автоматизация'), content: automation },
            { id: 'stgws-package', label: _('Пакет'), content: packages }
        ]);
        return {
            id: 'module-stgws', label: entry.name, activate: load,
            content: [
                E('div', { class: 'ows-module-heading' }, [E('h3', {}, entry.name), refresh]),
                tabs.content, notice, log
            ]
        };
    }
});
