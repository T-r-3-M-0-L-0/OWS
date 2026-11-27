'use strict';
'require view';
'require rpc';

var state = rpc.declare({object:'ows', method:'vpn_state', params:['id']});
var native;

return view.extend({
    load: function() {
        return state('netshift').then(function(data) {
            var path = data.ui && data.ui.native_view;
            if (typeof path !== 'string' || !/^netshift(_[a-f0-9]{1,64})?\/netshift$/.test(path))
                throw new Error(_('Штатный интерфейс NetShift недоступен. Проверьте установку пакета.'));
            return L.require('view.' + path.replace('/', '.'));
        }).then(function(pane) {
            native = pane;
            return native.load();
        });
    },
    render: function(data) { return native.render(data); },
    addFooter: function() { return native.addFooter(); }
});
