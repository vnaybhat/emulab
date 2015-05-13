require(window.APT_OPTIONS.configObject,
	['underscore', 'js/quickvm_sup'],
function (_, sup)
{
    'use strict';
    
    function initialize()
    {
	// We share code with the modal version of login, and the
	// handler for the button is installed in initialize().
	// See comment there.
	if (window.ISCLOUD) {
	    sup.InitGeniLogin();
	}
	window.APT_OPTIONS.initialize(sup);
    }
    $(document).ready(initialize);
});
