require(window.APT_OPTIONS.configObject,
	['underscore', 'js/quickvm_sup',
	 'js/lib/text!template/invite.html'],
function (_, sup, inviteString)
{
    'use strict';
    var inviteTemplate    = _.template(inviteString);

    function initialize()
    {
	window.APT_OPTIONS.initialize(sup);

	var fields   = JSON.parse(_.unescape($('#form-json')[0].textContent));
	var errors   = JSON.parse(_.unescape($('#error-json')[0].textContent));
	var projlist = JSON.parse(_.unescape($('#projects-json')[0].textContent));

	// Generate the templates.
	var invite_html = inviteTemplate({
	    formfields:		fields,
	    projects:		projlist,
	    general_error:      (errors.error || '')
	});
	$('#invite-body').html(formatter(invite_html, errors).html());
    }

    function formatter(fieldString, errors)
    {
	var root   = $(fieldString);
	var list   = root.find('.format-me');
	list.each(function (index, item) {
	    if (item.dataset) {
		var key     = item.dataset['key'];
		var wrapper = $('<div></div>');
		wrapper.addClass('sidebyside-form');
		wrapper.addClass('form-group');
		wrapper.html($(item).clone());

		if (_.has(errors, key))
		{
		    wrapper.addClass('has-error');
		    wrapper.append('<label class="control-label" ' +
				   'for="inputError">' + _.escape(errors[key]) +
				   '</label>');
		}
		$(item).after(wrapper);
		$(item).remove();
	    }
	});
	return root;
    }
    $(document).ready(initialize);
});
