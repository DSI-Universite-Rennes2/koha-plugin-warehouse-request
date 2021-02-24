<script>
let wr_borrowernumber;

$(document).ready(function() {
    if ($('#opac-user').length > 0) {
        wr_borrowernumber = $(".loggedinusername").data('borrowernumber');
        var tabs = $('#opac-user-views').tabs();
        var ul = tabs.find('ul');
        $('<li><a href="#warehouse-requests" id="wrm-tab">Demandes de document (?)</a></li>').appendTo(ul);
        $('<div id="warehouse-requests">Chargement...</div>').appendTo(tabs);
        tabs.tabs("refresh");
        refreshWarehouseRequests(wr_borrowernumber);
    }
});

function refreshWarehouseRequests(borrowernumber) {
    $.get(`/api/v1/contrib/wrm/patrons/${borrowernumber}/requests`, function (data) {
        var cnt = 0;
        var result = $('#warehouse-requests').empty();
        result.append(`
                    <table class="table table-bordered table-striped dataTable no-footer" role="grid">
                        <tbody>
                        </tbody>
                    </table>
                    `);
        if (data.length > 0) {
            result.find('table').prepend(`
                            <caption>Demandes de document (`+ data.length + ` en tout) </caption>
                            <thead>
                                <tr>
                                    <th>Informations</th>
                                    <th>Demand&eacute; le</th>
                                    <th>A retirer avant le</th>
                                    <th>Statut</th>
                                    <th>Site de retrait</th>
                                </tr>
                            </thead>
                        `);
            data.sort(function (a, b) { return b.id - a.id });
            for (var i = 0; i < data.length; i++) {
                console.log(data[i]);
                var cd = new Date(data[i].created_on);
                var rd = new Date(data[i].deadline);
                var infoBlock = '<a href="/bib/' + data[i].biblionumber + '" title="' + data[i].biblio.title + '">' + data[i].biblio.title + '</a> ' + data[i].biblio.author + ' <span class="label">(Seulement ' + data[i].item.itemcallnumber + ')</span>';
                var extInfoBlock = [];
                if (data[i].volume != '' && data[i].volume != undefined) extInfoBlock.push('<span class="label">Volume(s) : ' + data[i].volume + '</span>');
                if (data[i].issue != '' && data[i].issue != undefined) extInfoBlock.push('<span class="label">Numéro(s) : ' + data[i].issue + '</span>');
                if (data[i].date != '' && data[i].date != undefined) extInfoBlock.push('<span class="label">Date : ' + data[i].date + '</span>');
                if (extInfoBlock.length > 0) infoBlock += '<br />' + extInfoBlock.join(' | ');
                result.find('tbody').append(`
                                <tr>
                                    <td>`+ infoBlock + `</td>
                                    <td>`+ cd.toLocaleDateString() + ' ' + cd.toLocaleTimeString() + `</td>
                                    <td>`+ rd.toLocaleDateString() + `</td>
                                    <td class="nowrap">`+ colorStatus(data[i].statusstr, data[i].status) + (data[i].status == 'CANCELED' ? '<div class="reason">' + data[i].notes + '</div>' : '') + `</td>
                                    <td>`+ data[i].branchname + `</td>
                                </tr>
                            `);
                if (['CANCELED', 'COMPLETED'].indexOf(data[i].status) < 0) {
                    cnt++;
                }
                $('#wrm-tab').text('Demandes de document (' + cnt + ')');
            }
            $('.cancel-wr').click(function () {
                if (confirm('Êtes-vous sûr(e) de vouloir annuler votre demande ?')) {
                    var id = $(this).attr('data-id');
                    $.post("/api/v1/contrib/wrm/cancel/" + id, function (data) {
                        alert('Votre demande a été annulée avec succès');
                        refreshWarehouseRequests();
                    });
                }
            });
        } else {
            result.find('tbody').append('<tr><td>Aucune demande en cours</td></tr>');
        }
    });
}

function colorStatus(str, code) {
    var cls = "label";
    switch (code) {
        case "PENDING":
        case "PROCESSING":
            cls += " label-warning";
            break;
        case "WAITING":
            cls += " label-success";
            break;
        case "COMPLETED":
            cls += " bg-gray text-white";
            break;
        case "CANCELED":
            cls += " label-danger";
            break;
    }
    return '<span class="' + cls + '">' + str + '</span>';
}
</script>