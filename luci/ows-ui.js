'use strict';
'require baseclass';
'require rpc';

var jobOutput = rpc.declare({object:'ows', method:'job_output', params:['job']});

function checked(data) {
    if (!data || data.error) throw new Error((data && data.error) || _('Нет ответа от OWS'));
    return data;
}

return baseclass.extend({
    checked: checked,
    deferredTab: function(id, label, build) {
        var content = E('div');
        var tab, pending;

        function invoke(method, value) {
            if (!tab && !pending) {
                content.textContent = _('Загрузка…');
                pending = Promise.resolve().then(build).then(function(result) {
                    tab = result;
                    content.replaceChildren(E('div', {}, tab.content));
                    return tab;
                }).catch(function() {
                    content.textContent = _('Не удалось загрузить вкладку. Откройте её ещё раз.');
                    return null;
                }).finally(function() { pending = null; });
            }
            return (tab ? Promise.resolve(tab) : pending).then(function(result) {
                if (result && result[method]) return result[method](value);
            });
        }

        return {id:id, label:label, content:content,
            activate:function() { return invoke('activate'); },
            openSection:function(value) { return invoke('openSection', value); }};
    },
    field: function(label, control) {
        return E('label', {class:'ows-field'}, [E('span', {}, label), control]);
    },
    button: function(label, action, disabled) {
        var button = E('button', {type:'button', class:'cbi-button'}, label);
        button.disabled = !!disabled;
        button.addEventListener('click', action);
        return button;
    },
    details: function(rows) {
        return rows.reduce(function(nodes, row) {
            nodes.push(E('dt', {}, row[0]), E('dd', {}, row[1] == null || row[1] === '' ? '—' : String(row[1])));
            return nodes;
        }, []);
    },
    feedback: function() {
        var notice = E('p', {role:'status'});
        var log = E('pre', {class:'ows-job-output', hidden:''});
        return {
            content: E('div', {}, [notice, log]),
            start: function(message) { notice.textContent = message; log.hidden = true; },
            show: function(message, output) {
                notice.textContent = message;
                log.textContent = output || '';
                log.hidden = !output;
            }
        };
    },
    showResult: function(feedback, result, failure) {
        var phase = result.status.phase;
        var ok = phase === 'done' || phase === 'applied';
        feedback.show(ok ? _('Операция завершена') : failure || _('Операция завершилась с ошибкой'), result.output);
    },
    table: function(headings, rows) {
        return E('table', {class:'table'}, [
            E('thead', {}, E('tr', {class:'tr table-titles'}, headings.map(function(label) {
                return E('th', {class:'th', scope:'col'}, label);
            }))),
            E('tbody', {}, rows.map(function(row) {
                return E('tr', {class:'tr'}, row.map(function(cell) { return E('td', {class:'td'}, cell); }));
            }))
        ]);
    },
    form: function(fields, label, submit) {
        var button = E('button', {type:'submit', class:'cbi-button'}, label);
        var form = E('form', {}, fields.concat(button));
        form.addEventListener('submit', function(event) {
            event.preventDefault();
            if (button.disabled) return;
            button.disabled = true;
            Promise.resolve().then(submit).finally(function() { button.disabled = false; });
        });
        return form;
    },
    job: function(request, follow, includeOutput) {
        return Promise.resolve(request).then(checked).then(function(data) {
            if (!data.job) throw new Error(_('Операция недоступна'));
            return new Promise(function(resolve) { follow(data.job, resolve); });
        }).then(function(status) {
            if (!includeOutput) return {status:status};
            return jobOutput(status.job).then(function(data) { return {status:status, output:data.output || ''}; });
        });
    }
});
