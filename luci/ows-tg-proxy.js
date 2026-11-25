'use strict';
'require baseclass';
'require rpc';

var info = rpc.declare({ object: 'ows', method: 'tg_proxy_info' });
var execute = rpc.declare({ object: 'ows', method: 'tg_proxy_action', params: ['action'] });

return baseclass.extend({
    tab: function(entry, follow) {
        var state = E('dl', {});
        var actions = E('div', { class: 'ows-actions' });
        var notice = E('p', { role: 'status' });
        var busy = false;
        var service = {};

        function button(label, handler, disabled) {
            var node = E('button', { type: 'button', class: 'cbi-button' }, label);
            node.disabled = disabled;
            node.addEventListener('click', handler);
            return node;
        }

        function renderActions() {
            var disabled = busy || !service.installed;
            actions.replaceChildren(
                button(_('Обновить состояние'), load, busy),
                button(_('Запустить'), function() { submit('start'); }, disabled || service.running),
                button(_('Перезапустить'), function() { submit('restart'); }, disabled || !service.running),
                button(_('Остановить'), function() { submit('stop'); }, disabled || !service.running)
            );
        }

        function load() {
            return info().then(function(data) {
                service = data;
                if (data.error) notice.textContent = data.error;
                state.replaceChildren(
                    E('dt', {}, _('Служба')), E('dd', {}, !data.installed ? _('Служба не установлена') :
                        data.running ? _('Прокси работает') : _('Прокси остановлен')),
                    E('dt', {}, _('Пакет')), E('dd', {}, data.version || '—'),
                    E('dt', {}, _('TCP-порт')), E('dd', {}, data.port == null ? '—' : String(data.port)),
                    E('dt', {}, _('Автозапуск')), E('dd', {}, data.enabled ? _('Включён') : _('Выключен'))
                );
            }).catch(function() {
                notice.textContent = _('Не удалось прочитать состояние прокси');
            }).finally(renderActions);
        }

        function submit(action) {
            if (busy) return;
            busy = true;
            renderActions();
            notice.textContent = _('Ставим операцию в очередь');
            execute(action).then(function(result) {
                if (!result.job) throw new Error(result.error || _('Операция недоступна'));
                follow(result.job, function(status) {
                    if (status.phase === 'queued' || status.phase === 'applying') return;
                    busy = false;
                    notice.textContent = status.phase === 'done' ? _('Операция завершена') :
                        _('Состояние службы не подтвердилось после операции');
                    load();
                });
            }).catch(function(error) {
                busy = false;
                notice.textContent = error.message || _('Запрос отклонён');
                renderActions();
            });
        }

        return {
            id: 'module-' + entry.id, label: entry.name, activate: load,
            content: [E('h3', {}, entry.name), state, actions, notice]
        };
    }
});
