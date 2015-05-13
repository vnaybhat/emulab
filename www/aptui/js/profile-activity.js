require(window.APT_OPTIONS.configObject,
	['underscore', 'js/quickvm_sup',
	 'js/lib/text!template/profile-activity.html'],
function (_, sup, profileString)
{
    'use strict';
    var ajaxurl = null;
    var profileTemplate = _.template(profileString);

    function initialize()
    {
	window.APT_OPTIONS.initialize(sup);
	ajaxurl  = window.AJAXURL;

	var instances =
	    JSON.parse(_.unescape($('#instances-json')[0].textContent));
	var activity_html = profileTemplate({instances: instances});
	$('#activity-body').html(activity_html);
    }
    $(document).ready(initialize);
});
