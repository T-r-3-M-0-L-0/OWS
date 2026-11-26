'use strict';
'require baseclass';
'require rpc';
'require view.ows-ui as owsUI';

var status = rpc.declare({object:'ows',method:'services_status'});

return baseclass.extend({
    panel: function(operationLabel, jobOutput) {
        var list = E('ul', {class:'ows-services-state',hidden:''});
        var notice = E('p', {role:'status'}, _('Загрузка состояний служб…'));
        var empty = E('p', {hidden:''}, _('Статусы дополнительных служб появятся после установки модулей.'));
        var last;
        var pending;
        var refresh = owsUI.button(_('Обновить службы'), load);
        var states = {
            ok: _('ОК'),
            main_ok: _('ОК · MAIN работает'),
            main_disabled: _('MAIN выключен в настройках'),
            main_stopped: _('MAIN не запущен'),
            stopped: _('Остановлена'),
            paused: _('Выключена'),
            partial: _('Часть экземпляров остановлена'),
            no_rules: _('Рабочие правила или список отсутствуют'),
            unknown: _('Состояние недоступно')
        };
        var errors = {
            oom: _('Ядро завершило процесс из-за нехватки памяти'),
            crash_loop: _('Служба циклически завершалась с ошибкой'),
            system_error: _('Ошибка службы в системном журнале')
        };

        function errorRow(error) {
            var date = new Date(error.time * 1000);
            var item = [E('time', {datetime:date.toISOString()}, date.toLocaleString()),
                ' · ', error.job ? operationLabel(error) : errors[error.phase] || _('Ошибка')];
            if (error.job) {
                var output = E('pre', {class:'ows-job-output'});
                var log = E('details', {}, [E('summary', {}, _('Журнал задания')), output]);
                var loaded = false;
                log.addEventListener('toggle', function() {
                    if (!log.open || loaded) return;
                    loaded = true;
                    output.textContent = _('Читаем журнал задания');
                    jobOutput(error.job).then(owsUI.checked).then(function(data) {
                        output.textContent = data.output || _('Журнал пуст');
                    }).catch(function() {
                        output.textContent = _('Журнал задания недоступен.');
                    });
                });
                item.push(log);
            }
            return E('li', {}, item);
        }

        function serviceRow(service) {
            return E('li', {class:'ows-service-state'}, [
                E('div', {class:'ows-service-state-heading'}, [
                    E('strong', {}, service.name),
                    E('span', {'data-state':service.state}, states[service.state] || states.unknown)
                ]),
                service.errors.length ? E('ul', {class:'ows-service-errors','aria-label':_('Последние ошибки')},
                    service.errors.map(errorRow)) : ''
            ]);
        }

        function load() {
            if (pending) return pending;
            refresh.disabled = true;
            pending = status().then(owsUI.checked).then(function(data) {
                var snapshot = JSON.stringify(data.services);
                if (snapshot !== last) {
                    list.replaceChildren.apply(list, data.services.map(serviceRow));
                    list.hidden = !data.services.length;
                    empty.hidden = data.services.some(function(service) { return service.id !== 'dnsmasq'; });
                    last = snapshot;
                }
                notice.textContent = '';
                notice.hidden = true;
            }).catch(function() {
                notice.textContent = _('Не удалось обновить состояния служб.');
                notice.hidden = false;
            }).finally(function() {
                refresh.disabled = false;
                pending = null;
            });
            return pending;
        }

        return {load:load, content:E('section', {class:'ows-service-summary'}, [
            E('div', {class:'ows-module-heading'}, [E('strong', {}, _('Состояние служб')), refresh]),
            notice, list, empty
        ])};
    }
});
