require(window.APT_OPTIONS.configObject,
	['underscore', 'js/quickvm_sup',
	 'js/lib/text!template/profile-history.html'],
function (_, sup, profileString)
{
    'use strict';
    var ajaxurl = null;
    var profileTemplate = _.template(profileString);

    function initialize()
    {
	window.APT_OPTIONS.initialize(sup);
	ajaxurl  = window.AJAXURL;

	var profiles = JSON.parse(_.unescape($('#profiles-json')[0].textContent));
	var profile_html = profileTemplate({profiles: profiles});
	$('#history-body').html(profile_html);

	console.info(profiles);
    }
    $(document).ready(initialize);
});
