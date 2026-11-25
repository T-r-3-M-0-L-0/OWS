'use strict';
'require baseclass';
'require rpc';

var info = rpc.declare({object:'ows',method:'dns_info'});
var check = rpc.declare({object:'ows',method:'dns_check'});
var output = rpc.declare({object:'ows',method:'job_output',params:['job']});

return baseclass.extend({
    tab: function(followJob) {
        var summary = E('dl', {});
        var notice = E('p', {role:'status'});
        var log = E('pre', {class:'ows-job-output',hidden:''});
        var run = E('button', {type:'button',class:'cbi-button'}, _('Проверить DNS'));

        function load() {
            function state(value) { return value ? _('Активно') : _('Не обнаружено'); }
            return info().then(function(data) {
                summary.replaceChildren(
                    E('dt', {}, 'dnsmasq'),E('dd', {}, state(data.dnsmasq)),
                    E('dt', {}, _('DNS-watchdog NetShift')),E('dd', {}, state(data.watchdog)),
                    E('dt', {}, _('Список AdBlock Fast')),E('dd', {}, state(data.adblock)),
                    E('dt', {}, _('Обновление списка')),E('dd', {}, data.last_update > 0 ?
                        new Date(data.last_update * 1000).toLocaleString() : '—')
                );
            }).catch(function() { notice.textContent = _('Не удалось прочитать состояние DNS'); });
        }

        run.addEventListener('click', function() {
            run.disabled = true;
            log.hidden = true;
            notice.textContent = _('Ставим проверку DNS в очередь…');
            check().then(function(data) {
                if (!data.job) throw new Error(data.error || _('Проверка недоступна'));
                followJob(data.job, function(result) {
                    notice.textContent = result.phase === 'done' ? _('Проверка завершена') : _('Проверка выявила сбой');
                    output(result.job).then(function(data) {
                        log.textContent = data.output || '';
                        log.hidden = !log.textContent;
                    }).catch(function() { notice.textContent = _('Не удалось прочитать журнал проверки'); })
                        .finally(function() { run.disabled = false; });
                    load();
                });
            }).catch(function(error) { notice.textContent = error.message; run.disabled = false; });
        });
        return {id:'dns',label:_('DNS'),activate:load,content:E('div', {}, [summary,run,notice,log])};
    }
});
