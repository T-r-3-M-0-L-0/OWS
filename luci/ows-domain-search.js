'use strict';
'require baseclass';
'require rpc';
'require view.ows-ui as owsUI';

var search = rpc.declare({object:'ows', method:'domain_search', params:['domain']});

return baseclass.extend({
    panel: function(openMatch) {
        var names = {steer:'steer', zapret2:'Zapret2', adblock:_('Блокировка рекламы')};
        var roles = {hostlist:_('Список тактики'), hostlist_exclude:_('Исключение из тактики'), hostlist_auto:_('Автохостлист')};
        var domain = E('input', {type:'text', class:'cbi-input-text', maxlength:254, placeholder:'youtube.com', required:''});
        var notice = E('p', {role:'status'});
        var results = E('div');

        function ruleText(match) {
            if (match.module === 'adblock') return match.effect === 'block' ? _('Блокирующее правило DNS') : _('Исключение DNS');
            if (!match.rules || !match.rules.length) return _('Связанное правило не найдено');
            return E('ul', {}, match.rules.map(function(rule) {
                var target = match.module === 'steer' ? rule.out : roles[rule.role];
                return E('li', {}, [rule.name || '—', target ? ' → ' + target : '', rule.active === false ? ' · ' + _('выключено') : '']);
            }));
        }

        function render(data) {
            var rows = data.matches || [];
            notice.textContent = [rows.length ? _('Совпадений') + ' · ' + rows.length : _('Совпадений не найдено.'),
                _('Проверено') + ' · ' + (data.sources || []).map(function(key) { return names[key]; }).join(', '),
                data.partial ? _('Часть списков пропущена из-за размера или недоступности.') : ''].filter(Boolean).join(' ');
            if (!rows.length) return;
            var headings = [_('Модуль и список'), _('Совпадение'), _('Правило'), _('Действие')];
            results.replaceChildren(owsUI.table(headings, rows.map(function(row) {
                var open = owsUI.button(_('Открыть'), function() {
                    if (!openMatch(row)) notice.textContent = _('Подключите модуль в «Обзоре», чтобы открыть его настройки.');
                });
                return [[names[row.module] || row.module, ' · ', E('code', {}, row.list)],
                    [E('code', {}, row.matched), ' · ', row.match === 'exact' ? _('точное') : _('родительский домен')],
                    ruleText(row), open];
            })));
        }

        var form = owsUI.form([owsUI.field(_('Домен'), domain)], _('Найти'), function() {
            var query = domain.value.trim();
            if (!query) return;
            results.replaceChildren();
            notice.textContent = _('Проверяем локальные списки…');
            return search(query).then(owsUI.checked).then(render)
                .catch(function(error) { notice.textContent = error.message || _('Поиск недоступен'); });
        });

        return E('section', {class:'ows-section'}, [E('h3', {}, _('Поиск домена')), form, notice, results]);
    }
});
