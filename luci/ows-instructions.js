'use strict';
'require baseclass';
'require rpc';
'require view.ows-ui as owsUI';
'require view.ows-markdown as markdown';

var list = rpc.declare({object:'ows', method:'instructions_list'});
var read = rpc.declare({object:'ows', method:'instructions_read', params:['id']});
var write = rpc.declare({object:'ows', method:'instructions_write', params:['operation','id','expected','content']});

return baseclass.extend({
    tab: function() {
        var selected = E('select', {class:'cbi-input-select'});
        var article = E('article');
        var status = E('p', {role:'status'});
        var editor = E('textarea', {class:'cbi-input-text ows-instructions-editor', rows:20,
            'aria-label':_('Текст документа Markdown')});
        var name = E('input', {class:'cbi-input-text', type:'text', maxlength:80, placeholder:'novyj-dokument'});
        var nameField = owsUI.field(_('Имя файла'), name);
        var permission = L.hasViewPermission();
        var writable = false;
        var busy = false;
        var loaded = false;
        var mode = '';
        var current;

        function sync() {
            selected.disabled = busy || !!mode || !selected.options.length;
            refresh.disabled = busy || !!mode;
            edit.disabled = busy || !current;
            add.disabled = busy;
            edit.hidden = add.hidden = !permission || !writable || !!mode;
            article.hidden = !!mode;
            editor.hidden = save.hidden = cancel.hidden = !mode;
            nameField.hidden = mode !== 'create';
            name.disabled = editor.disabled = save.disabled = cancel.disabled = busy;
        }

        function showDocument() {
            current = null;
            article.replaceChildren();
            if (!selected.value) return Promise.resolve();
            return read(selected.value).then(owsUI.checked).then(function(doc) {
                current = doc;
                article.replaceChildren(markdown.render(doc.log));
            });
        }

        function reload(preferred) {
            return list().then(owsUI.checked).then(function(data) {
                writable = !!data.writable;
                var docs = data.documents || [];
                selected.replaceChildren.apply(selected, docs.map(function(doc) {
                    return E('option', {value:doc.id}, doc.title);
                }));
                selected.value = docs.some(function(doc) { return doc.id === preferred; }) ? preferred :
                    docs.some(function(doc) { return doc.id === 'zapret2'; }) ? 'zapret2' : (docs[0] || {}).id || '';
                return showDocument();
            }).then(function() { loaded = true; });
        }

        function perform(action, success) {
            if (busy) return;
            busy = true;
            status.textContent = _('Загрузка…');
            sync();
            return action().then(function() {
                status.textContent = success || (writable ? '' : _('Чтение доступно. Редактирование откроется после передачи управления OWS.'));
            }).catch(function(error) { status.textContent = error.message || _('Не удалось выполнить операцию.'); })
                .finally(function() { busy = false; sync(); });
        }

        function start(operation) {
            mode = operation;
            name.value = '';
            editor.value = operation === 'create' ? '# ' : current.log;
            status.textContent = '';
            sync();
            (operation === 'create' ? name : editor).focus();
        }

        var refresh = owsUI.button(_('Обновить'), function() { return perform(function() { return reload(selected.value); }); });
        var edit = owsUI.button(_('Редактировать'), function() { start('write'); });
        var add = owsUI.button(_('Добавить документ'), function() { start('create'); });
        var cancel = owsUI.button(_('Отмена'), function() { mode = ''; status.textContent = ''; sync(); });
        var save = owsUI.button(_('Сохранить'), function() {
            var id = mode === 'create' ? name.value.trim() : selected.value;
            if (!/^[a-z0-9-]{1,80}$/.test(id) || !editor.value.trim()) {
                status.textContent = _('Укажите имя из строчных латинских букв, цифр и дефисов и заполните документ.');
                return;
            }
            var revision = mode === 'write' ? current.revision : '';
            return perform(function() {
                return write(mode, id, revision, editor.value).then(owsUI.checked).then(function() {
                    mode = '';
                    return reload(id);
                });
            }, _('Документ сохранён.'));
        });
        selected.addEventListener('change', function() { perform(showDocument); });
        sync();
        return {id:'instructions', label:_('Инструкции'), activate:function() {
            if (!loaded) return perform(function() { return reload(); });
        }, content:E('section', {class:'ows-instructions'}, [
            owsUI.field(_('Документ'), selected),
            E('div', {class:'ows-actions'}, [refresh,edit,add]),
            status, article, nameField, editor, E('div', {class:'ows-actions'}, [save,cancel])
        ])};
    }
});
