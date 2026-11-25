'use strict';
'require baseclass';
'require rpc';

var hasAccess = rpc.declare({
    object: 'session', method: 'access', params: ['scope', 'object', 'function'], expect: { access: false }
});

return baseclass.extend({
    tab: function(options) {
        var panel = E('div', { class: 'ows-native' });
        var label = options.label || _('Штатные настройки');
        var pending;
        function fitFrame(frame) {
            var doc = frame.contentDocument;
            if (!doc || !doc.getElementById('view')) return;

            var style = doc.createElement('style');
            style.textContent = [
                'body { margin: 0 !important; padding: 0 !important; }',
                'body > header, body > footer, #mainmenu, #tabmenu, #indicator, #indicators,',
                '.main-left, .showSide { display: none !important; }',
                '#maincontent { margin: 0 !important; padding: 0 !important; max-width: none !important; }'
            ].join('\n');
            doc.head.appendChild(style);

        }

        function load() {
            if (pending) return pending;
            panel.replaceChildren(E('p', { role: 'status' }, _('Загружаем штатный интерфейс…')));
            pending = Promise.resolve().then(options.available || function() { return true; }).then(function(available) {
                if (!available) throw new Error(_('Установите пакет штатного интерфейса во вкладке «Служба и пакеты».'));
                return hasAccess('access-group', options.acl, 'read');
            }).then(function(allowed) {
                if (!allowed) throw new Error(_('У этой учётной записи нет доступа к штатному интерфейсу.'));
                // A LuCI view owns #view during construction and may reload its document after applying changes.
                var frame = E('iframe', {
                    class: 'ows-native-frame', title: label,
                    src: L.url('admin', 'services', options.route)
                });
                frame.addEventListener('load', function() { fitFrame(frame); });
                panel.replaceChildren(frame);
            }).catch(function(error) {
                panel.replaceChildren(E('p', { role: 'alert' }, error.message || _('Штатный интерфейс недоступен.')),
                    E('button', { type: 'button', class: 'cbi-button', click: load }, _('Повторить')));
                pending = null;
            });
            return pending;
        }

        return { id: options.id, label: label, content: panel, activate: load };
    }
});
