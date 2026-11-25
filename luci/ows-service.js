'use strict';
'require baseclass';
'require rpc';

return baseclass.extend({
    tab: function(entry, follow, template) {
        var info = rpc.declare({ object: 'ows', method: template.statusMethod });
        var execute = rpc.declare({ object: 'ows', method: template.actionMethod, params: ['action'] });
        var state = E('dl', {});
        var actions = E('div', { class: 'ows-actions' });
        var notice = E('p', { role: 'status' });
        var busy = false;
        var pending;
        var service = {};

        function button(label, handler, disabled) {
            var node = E('button', { type: 'button', class: 'cbi-button' }, label);
            node.disabled = !!disabled;
            node.addEventListener('click', handler);
            return node;
        }

        function renderActions() {
            var disabled = busy || !service.installed;
            var controls = template.actions.map(function(action) {
                return button(action.label, function() { submit(action.id); }, disabled ||
                    (action.enabled && !action.enabled(service)));
            });
            actions.replaceChildren.apply(actions, [button(_('Обновить состояние'), load, busy)].concat(controls));
        }

        function load() {
            if (pending) return pending;
            pending = info().then(function(data) {
                service = data;
                if (data.error) notice.textContent = data.error;
                var fields = template.fields.reduce(function(nodes, field) {
                    var value = field.value(data);
                    nodes.push(E('dt', {}, field.label), E('dd', {}, value == null || value === '' ? '—' : String(value)));
                    return nodes;
                }, []);
                state.replaceChildren.apply(state, fields);
            }).catch(function() {
                service = {};
                notice.textContent = template.readError || _('Не удалось прочитать состояние службы');
            }).finally(function() {
                pending = null;
                renderActions();
            });
            return pending;
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
