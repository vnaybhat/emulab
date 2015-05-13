window.APT_OPTIONS = window.APT_OPTIONS || {};

window.APT_OPTIONS.configObject = {
    baseUrl: '.',
    paths: {
	'jquery-ui': 'js/lib/jquery-ui',
	'jquery-grid':'js/lib/jquery.appendGrid-1.3.1.min',
	'formhelpers': 'js/lib/bootstrap-formhelpers',
	'dateformat': 'js/lib/date.format',
	'd3': 'js/lib/d3.v3',
	'filestyle': 'js/lib/filestyle',
	'tablesorter': 'js/lib/jquery.tablesorter.min',
	'tablesorterwidgets': 'js/lib/jquery.tablesorter.widgets.min',
	'marked': 'js/lib/marked',
	'moment': 'js/lib/moment',
	'underscore': 'js/lib/underscore-min',
	'filesize': 'js/lib/filesize.min',
	'jacks': 'https://www.emulab.net/protogeni/jacks-stable/js/jacks'
    },
    shim: {
	'jquery-ui': { },
	'jquery-grid': { deps: ['jquery-ui'] },
	'formhelpers': { },
	'dateformat': { exports: 'dateFormat' },
	'd3': { exports: 'd3' },
	'filestyle': { },
	'tablesorter': { },
	'tablesorterwidgets': { deps: ['tablesorter'] },
	'marked' : { exports: 'marked' },
	'underscore': { exports: '_' },
	'filesize' : { exports: 'filesize' }
    }
};

window.APT_OPTIONS.initialize = function (sup)
{
    var geniauth = "https://www.emulab.net/protogeni/speaks-for/geni-auth.js";

    // Every page calls this, and since the Login button is on every
    // page, do this initialization here. 
    if ($('#quickvm_geni_login_button').length) {
	$('#quickvm_geni_login_button').click(function (event) {
	    event.preventDefault();
	    if ($('#quickvm_login_modal').length) {
		sup.HideModal("#quickvm_login_modal");
	    }
	    sup.StartGeniLogin();
	    return false;
	});
    }
    // When the user clicks on the login button, we not only display
    // the modal, but fire off the load of the geni-auth.js file so
    // that the code is loaded. Something to do with popup rules from
    // javascript event handlers, blah blah blah. Ask Jon.
    if ($('#loginbutton').length) {
	$('#loginbutton').click(function (event) {
	    event.preventDefault();
	    sup.ShowModal('#quickvm_login_modal');
	    if (window.ISCLOUD) {
		console.info("Loading geni auth code");
		sup.InitGeniLogin();
		require([geniauth], function() {
		    console.info("Geni auth code has been loaded");
		    $('#quickvm_geni_login_button').removeAttr("disabled");
		});
	    }
	    return false;
	});
    }
    $('body').show();
}
