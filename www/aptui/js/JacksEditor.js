define(['underscore', 'js/lib/text!template/edit-modal.html'],
function (_, editModalString)
{
    'use strict';

    function JacksEditor (root)
    {
	this.root = root;
	this.instance = null;
	this.input = null;
	this.output = null;
	this.xml = null;
	this.render();
    }

    JacksEditor.prototype = {

	render: function ()
	{
	    this.root.html(editModalString);
	    this.root.find('#quickvm_editmodal').on('shown.bs.modal', _.bind(this.handleShown, this));
	    this.root.find('#edit-save').click(_.bind(this.fetchXml, this));
	    this.instance = new window.Jacks({
		mode: 'editor',
		source: 'rspec',
		root: '#edit_nopicker',
		nodeSelect: true,
		readyCallback: _.bind(this.jacksReady, this),
		show: {
		    rspec: false,
		    tour: false,
		    version: false,
		    menu: true,
		    selectInfo: true
		},
		canvasOptions: {
		    "defaults": [
			{
			    "name": "Add VM",
			    "image": "urn:publicid:IDN+utahddc.geniracks.net+image+emulab-ops:UBUNTU12-64-STD",
			    "type": "emulab-xen"
			}
		    ],
		    "images": [
/*
			{
			    "id": "urn:publicid:IDN+utahddc.geniracks.net+image+emulab-ops:FBSD100-64-STD",
			    "name": "FreeBSD 10.0 64-bit version"
			},
*/
			{
			    "id": "urn:publicid:IDN+utahddc.geniracks.net+image+emulab-ops:UBUNTU12-64-STD",
			    "name": "Ubuntu 12.04 LTS 64-bit"
			}/*,
			{
			    "id": "urn:publicid:IDN+utahddc.geniracks.net+image+emulab-ops:UBUNTU14-64-STD",
			    "name": "Ubuntu 14.04 LTS 64-bit"
			}*/
		    ],
		    "types": [
			{
			    "id": "emulab-xen",
			    "name": "Emulab Xen VM"
			}
		    ]
		}
	    });
	},

	// Show a modal that lets the user edit their rspec. Callback
	// is called with a new rspec if they click ok.
	show: function (newXml, callback)
	{
	    this.xml = newXml;
	    this.callback = callback;
	    if (this.input)
	    {
		this.root.find('#quickvm_editmodal').modal('show');
	    }
	},

	// Hide the modal.
	hide: function ()
	{
	    this.xml = null;
	    this.root.find('#quickvm_editmodal').modal('hide');
	},

	handleShown: function ()
	{
	    var expression = /^\s*$/;
	    if (this.xml && ! expression.exec(this.xml))
	    {
		var rspec = $.parseXML(this.xml);
		convertNamespace(rspec.documentElement);
		this.input.trigger('change-topology',
				   [{ rspec: rspec.documentElement.outerHTML }]);
	    }
	    else
	    {
		this.input.trigger('change-topology', [{
		    rspec:
		    '<rspec '+
			'xmlns="http://www.geni.net/resources/rspec/3" '+
			'xmlns:emulab="http://www.protogeni.net/resources/rspec/ext/emulab/1" '+
			'xmlns:tour="http://www.protogeni.net/resources/rspec/ext/apt-tour/1" '+
			'xmlns:jacks="http://www.protogeni.net/resources/rspec/ext/jacks/1" '+
			'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '+
			'xsi:schemaLocation="http://www.geni.net/resources/rspec/3 http://www.geni.net/resources/rspec/3/request.xsd">'+
			'</rspec>'
		}]);
	    }
	},

	jacksReady: function (input, output)
	{
	    this.input = input;
	    this.output = output;
	    if (this.xml)
	    {
		this.show(this.xml);
	    }
	},

	fetchXml: function ()
	{
	    var that = this;
	    var fetchDone = function (topology) {
		that.output.off('fetch-topology', fetchDone);
		that.callback(topology[0].rspec);
		that.hide();
	    };

	    this.output.on('fetch-topology', fetchDone);
	    this.input.trigger('fetch-topology');
	}
    };

    var v2ns = 'http://www.protogeni.net/resources/rspec/2';
    var v3ns = 'http://www.geni.net/resources/rspec/3';

    function convertNamespace(el)
    {
	if (el.namespaceURI === v2ns)
	{
	    el.setAttribute('xmlns', v3ns);
	}
	_.each(el.children, convertNamespace);
    }

    return JacksEditor;
});
