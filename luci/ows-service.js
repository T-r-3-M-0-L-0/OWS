'use strict';
'require baseclass';
'require rpc';
'require view.ows-ui as owsUI';

return baseclass.extend({
    tab: function(entry, follow, template) {
        var info = rpc.declare({object:'ows',method:template.statusMethod});
        var execute = rpc.declare({object:'ows',method:template.actionMethod,params:['action']});
        var state = E('dl');
        var actions = E('div', {class:'ows-actions'});
        var settings = E('fieldset');
        var feedback = owsUI.feedback();
        var busy = false;
        var pending;
        var service;

        function control() {
            return service && template.control ? template.control.select(service) : null;
        }

        function canWrite() {
            var ownership = control();
            return !template.control || !!(ownership && ownership.ready);
        }

        function renderActions() {
            var controls = [owsUI.button(_('Обновить состояние'), load, busy || !!pending)];
            var ownership = control();
            if (ownership && ownership.can_takeover) {
                controls.push(owsUI.button(template.control.actionLabel, function() {
                    submit(template.control.action);
                }, busy || !!pending));
            }
            if (service) template.actions.forEach(function(action) {
                if (action.visible && !action.visible(service)) return;
                controls.push(owsUI.button(action.label, function() {
                    if (!action.confirmation || window.confirm(action.confirmation)) submit(action.id);
                }, busy || !!pending || !canWrite() || (action.requiresInstalled !== false && !service.installed) ||
                    (action.enabled && !action.enabled(service))));
            });
            settings.disabled = busy || !!pending || !canWrite();
            actions.replaceChildren.apply(actions, controls);
        }

        function renderSettings() {
            var form = template.form;
            settings.hidden = !form || !service || (form.visible && !form.visible(service));
            if (settings.hidden) return;
            var fields = form.fields.map(function(field) {
                var control;
                if (field.options) {
                    control = E('select', {class:'cbi-input-select'}, field.options(service).map(function(option) {
                        return E('option', {value:option.value}, option.label);
                    }));
                } else {
                    control = E('input', {type:'number',class:'cbi-input-text',required:'',min:field.min,
                        max:typeof field.max === 'function' ? field.max(service) : field.max});
                }
                control.value = field.value(service);
                return {name:field.name,control:control,field:owsUI.field(field.label, control)};
            });
            settings.replaceChildren(E('legend', {}, form.label), owsUI.form([
                E('div', {class:'ows-fields'}, fields.map(function(field) { return field.field; }))
            ], form.submitLabel, function() {
                return submit(form.action(Object.fromEntries(fields.map(function(field) {
                    return [field.name,field.control.value];
                }))));
            }));
        }

        function load() {
            if (pending) return pending;
            pending = info().then(owsUI.checked).then(function(data) {
                service = template.select ? template.select(data) : data;
                var rows = template.fields.filter(function(field) {
                    return !field.visible || field.visible(service);
                }).map(function(field) { return [field.label, field.value(service)]; });
                if (template.control) rows.unshift([template.control.label, template.control.value(control())]);
                state.replaceChildren.apply(state, owsUI.details(rows));
            }).catch(function(error) {
                service = null;
                state.replaceChildren();
                feedback.show(error.message || template.readError || _('Не удалось прочитать состояние службы'));
            }).finally(function() {
                pending = null;
                renderSettings();
                renderActions();
            });
            renderActions();
            return pending;
        }

        function submit(action) {
            if (busy || pending) return;
            var ownership = control();
            if (!canWrite() && !(ownership && ownership.can_takeover && action === template.control.action)) return;
            busy = true;
            renderActions();
            feedback.start(_('Ставим операцию в очередь…'));
            return owsUI.job(execute(action), follow, true).then(function(result) {
                owsUI.showResult(feedback, result);
            }).catch(function(error) { feedback.show(error.message); }).finally(function() {
                busy = false;
                return load();
            });
        }

        renderSettings();
        renderActions();
        return {id:'module-' + entry.id,label:entry.name,activate:load,
            content:[template.description ? E('p', {},template.description) : '',state,actions,settings,feedback.content]};
    }
});
