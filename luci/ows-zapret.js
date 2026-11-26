'use strict';
'require baseclass';
'require rpc';
'require view.ows-native as nativeView';
'require view.ows-ui as owsUI';

var field = owsUI.field, button = owsUI.button;

var info = rpc.declare({object:'ows', method:'zapret_module_info', params:['id']});
var action = rpc.declare({object:'ows', method:'zapret_module_action', params:['id','action']});
var constructorInfo = rpc.declare({object:'ows', method:'zapret_constructor', params:['topic']});
var jobOutput = rpc.declare({object:'ows', method:'job_output', params:['job']});

function actions(nodes) { return E('div', {class:'ows-actions'}, nodes); }

function rows(headings, items) {
    if (!items.length) return E('p', {}, _('Данных пока нет.'));
    return E('table', {class:'table'}, [
        E('thead', {}, E('tr', {class:'tr table-titles'}, headings.map(function(heading) {
            return E('th', {class:'th',scope:'col'}, heading);
        }))),
        E('tbody', {}, items.map(function(item) {
            return E('tr', {class:'tr'}, item.map(function(cell) { return E('td', {class:'td'}, String(cell || '—')); }));
        }))
    ]);
}

return baseclass.extend({
    init: function(id, followJob, profiles) {
        profiles = profiles || {};
        var panel = E('div');
        var constructor = E('div');
        var message = E('p', {'aria-live':'polite'});
        var log = E('pre', {class:'ows-job-output',hidden:''});
        var busy = false;
        var constructorOpened = false;
        var native = nativeView.tab({
            id: id + '-native',
            route: 'ows-native-' + id,
            acl: 'luci-app-' + id,
            revision: profiles.revision,
            onLoad: profiles.onNativeLoad,
            available: function() {
                return info(id).then(function(data) {
                    if (!data || data.error || data.id !== id)
                        throw new Error(_('Не удалось прочитать состояние пакета LuCI.'));
                    return !!data.native_view;
                });
            }
        });

        function submit(name, confirmation) {
            if (busy || (confirmation && !window.confirm(confirmation))) return;
            busy = true;
            log.hidden = true;
            message.textContent = _('Ставим действие в очередь…');
            action(id, name).then(function(result) {
                if (!result.job) throw new Error(result.error || _('Задание недоступно.'));
                message.textContent = _('Действие в очереди.');
                followJob(result.job, function(finalState) {
                    message.textContent = finalState.phase === 'done' ? _('Действие завершено.') : _('Действие не выполнено.');
                    jobOutput(result.job).then(function(details) {
                        log.textContent = details.output || '';
                        try {
                            var structured = JSON.parse(log.textContent);
                            log.textContent = [structured.message, structured.error, structured.plan, structured.log].filter(Boolean).join('\n') ||
                                log.textContent;
                        } catch (_) {}
                        log.hidden = !log.textContent;
                    }).catch(function() {}).finally(function() {
                        busy = false;
                        refresh();
                        if (constructorOpened) refreshConstructor();
                        if (finalState.phase === 'done' && /^builder-(create|apply)$/.test(name) && profiles.onApplied)
                            profiles.onApplied();
                    });
                });
            }).catch(function(error) {
                busy = false;
                message.textContent = error.message || _('Запрос отклонён.');
            });
        }

        function control(label, name, enabled, confirmation) {
            return button(label, function() { submit(name, confirmation); }, !enabled);
        }

        function refresh() {
            return info(id).then(function(data) {
                if (!data || data.error || data.id !== id) throw new Error();
                panel.replaceChildren(
                    E('p', {}, [
                        data.installed ? _('Установлен') + (data.version ? ' · ' + data.version : '') : _('Служба не установлена'),
                        data.installed ? ' · ' + (data.running ? _('работает') : _('остановлена')) : '',
                        data.enabled ? ' · ' + _('автозапуск включён') : ''
                    ]),
                    E('p', {}, [
                        E('a', {href:'https://github.com/' + data.repository + '/releases',target:'_blank',rel:'noopener noreferrer'},
                            data.repository), data.arch ? ' · ' + data.arch : '', data.format ? ' · ' + data.format : '',
                        data.downloaded ? ' · ' + _('Скачан релиз') + ' ' + data.downloaded : ''
                    ]),
                    data.conflict ? E('p', {}, _('Другой движок запущен или включён в автозапуск') + ' · ' + data.conflict) : '',
                    actions([
                        !data.installed ? control(_('Установить'), data.downloaded ? 'install' : 'install-latest',
                            data.arch && data.format && !data.conflict,
                            _('Установить движок и штатный интерфейс LuCI?')) : '',
                        control(_('Скачать пакеты'), 'download', data.arch && data.format),
                        data.installed ? control(_('Запустить'), 'start', !data.running && !data.conflict) : '',
                        data.installed ? control(_('Остановить'), 'stop', data.running,
                            _('Остановить рабочую службу?')) : '',
                        data.installed ? control(_('Перезапустить'), 'restart', data.running && !data.conflict) : '',
                        data.installed ? control(data.enabled ? _('Выключить автозапуск') : _('Включить автозапуск'),
                            data.enabled ? 'disable' : 'enable', data.enabled || !data.conflict) : ''
                    ])
                );
            }).catch(function() {
                panel.replaceChildren(E('p', {}, _('Не удалось прочитать состояние службы.')));
            });
        }

        function dnsSection(box) {
            var values = Promise.all(['dns-status','dns-domains','dns-learned'].map(constructorInfo));
            values.then(function(result) {
                var data = result[0].data || {};
                box.replaceChildren(E('dl', {}, Object.keys(data).flatMap(function(key) {
                    return [E('dt', {}, key), E('dd', {}, data[key])];
                })), rows([_('Домен')], result[1].rows || []),
                rows([_('Семейство'), _('Изученный адрес')], result[2].rows || []));
            }).catch(function() { box.textContent = _('Диагностика DNS недоступна.'); });
        }

        function refreshConstructor() {
            constructorOpened = true;
            return Promise.all([constructorInfo('status'), constructorInfo('targets')]).then(function(result) {
                var current = result[0];
                if (!current.available) {
                    constructor.replaceChildren(E('p', {}, current.error || _('Для конструктора нужен комплект strategy-check.')));
                    return;
                }
                var builder = current.builder || {};
                var targets = (result[1].rows || []).map(function(item) {
                    return [item.domain,item.kind,item.state,item.http,item.route];
                });
                var dnsHost = E('input', {type:'text',class:'cbi-input-text',maxlength:'253'});
                var dnsData = E('div');
                var dns = E('details', {class:'ows-section'}, [
                    E('summary', {}, _('DNS и обучение')),
                    dnsData, field(_('Домен'), dnsHost),
                    actions([
                        button(_('Проверить DNS'), function() { submit('dns-check:' + dnsHost.value.trim()); }),
                        button(_('Добавить домен'), function() { submit('dns-add:' + dnsHost.value.trim()); }),
                        button(_('Удалить домен'), function() { submit('dns-delete:' + dnsHost.value.trim()); })
                    ]),
                    actions([
                        control(_('Включить перенаправление'), 'dns-redirect-on', true,
                            _('Перенаправить запросы DNS из LAN на роутер?')),
                        control(_('Выключить перенаправление'), 'dns-redirect-off', true),
                        control(_('Включить обучение'), 'dns-learning-on', true),
                        control(_('Выключить обучение'), 'dns-learning-off', true)
                    ])
                ]);
                dns.addEventListener('toggle', function() { if (dns.open && !dnsData.hasChildNodes()) dnsSection(dnsData); });
                constructor.replaceChildren(
                    actions([button(_('Обновить статус'), refreshConstructor), control(_('Проверить цели'), 'health-run', true)]),
                    rows([_('Домен'), _('Тип'), _('Статус'), _('HTTP'), _('Маршрут')], targets),
                    E('h4', {}, _('Восстановление профилей')),
                    E('p', {}, builder.state || '—'),
                    actions([
                        control(_('Показать план'), 'builder-plan', true),
                        control(_('Создать кандидатов'), 'builder-create', true),
                        control(_('Проверить кандидатов'), 'builder-test', true),
                        control(_('Остановить проверку'), 'builder-stop', true),
                        control(_('Применить проверенных'), 'builder-apply', true,
                            _('Применить проверенные профили и перезапустить Zapret2?'))
                    ]),
                    E('pre', {class:'ows-job-output'}, [builder.candidates,builder.log,builder.apply_log].filter(Boolean).join('\n')),
                    current.dns ? dns : ''
                );
            }).catch(function() { constructor.replaceChildren(E('p', {}, _('Конструктор недоступен.'))); });
        }

        return {status:panel, native:native, constructor:constructor,
            feedback:E('div', {}, [message, log]), refresh:refresh, loadConstructor:refreshConstructor};
    }
});
