<script>
$(document).ready(function() {
    // Home button injection
    if ($('#main_intranet-main').length > 0) {
        $.get({
            url: "/api/v1/contrib/wrm/count",
            cache: true,
            success: function (data) {
                if (data.count > 0) {
                    var wrlink = `<div class="pending-info" id="warehouse_requests_pending">
                                    <a href="/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AFr%3A%3AUnivRennes2%3A%3AWRM&method=tool#warehouse-requests-processing">Demandes magasin</a>:
                                    <span class="pending-number-link">`+ data.count + `</span>
                                </div>`;
                    if ($('#area-pending').length > 0) {
                        $('#area-pending').prepend(wrlink);
                    } else {
                        $('#container-main > div.row > div.col-sm-9 > div.row:last-child div.col-sm-12').append('<div id="area-pending">' + wrlink + '</div>');
                    }
                }
            }
        });
    }
    // Circ homepage button injection
    if ($('#circ_circulation-home').length > 0) {
        var wrbutton = '<li><a class="circ-button" href="/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AFr%3A%3AUnivRennes2%3A%3AWRM&method=tool#warehouse-requests-processing" title="Demandes magasins"><i class="fa fa-file-text-o"></i> Demandes magasins</a></li>';
        var requestsMenu = $('i.fa-newspaper-o').parents('ul.buttons-list');
        if (requestsMenu.length > 0) {
            requestsMenu.prepend(wrbutton);
        } else {
            $('#circ_circulation-home div.main > div.row:first-child > div:last-child').prepend('<h3>Demandes des adhérents</h3><ul class="buttons-list">' + wrbutton + '</ul>');
        }
    }
    // Member tabs table injection
    if ($('#circ_circulation, #pat_moremember').length > 0) {
        var tabs = $('#patronlists, #finesholdsissues').tabs();
        tabs.find('ul li:last').before('<li><a href="#warehouse-requests" id="wrm-tab">? Demandes magasin</a></li>');
        tabs.find('div:last').before('<div id="warehouse-requests">Chargement...</div>');
        tabs.tabs("refresh");
        refreshWarehouseRequests();
    }
    // Catalog detail link
    let searchParams = new URLSearchParams(window.location.search);
    $('#catalog_detail #toolbar, #catalog_moredetail #toolbar').append('<div class="btn-group"><a id="placehold" class="btn btn-default " href="/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AFr%3A%3AUnivRennes2%3A%3AWRM&method=tool&op=creation&biblionumber=' + searchParams.get('biblionumber') + '"><i class="fa fa-file-text-o"></i> Demande magasin</a></div>');
    if ($('body.circ div#menu, body.catalog div#menu').length > 0 && searchParams.get('biblionumber') != undefined) {
        $('body.circ div#menu ul:first-child, body.catalog div#menu ul:first-child').append('<li><a id="wr-menu-link" href="/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AFr%3A%3AUnivRennes2%3A%3AWRM&method=tool&op=creation&biblionumber=' + searchParams.get('biblionumber') + '">Demandes magasin (?)</a></li>');
        $.get({
            url: "/api/v1/contrib/wrm/count?biblionumber=" + searchParams.get('biblionumber'),
            cache: true,
            success: function (data) {
                $('#wr-menu-link').text('Demandes magasin (' + data.count + ')');
            }
        });
        if ($('#circ_request-warehouse').length > 0) {
            $('#wr-menu-link').parent().addClass('active');
        }
    }
});

function refreshWarehouseRequests() {
    var borrowernumber = $('.patroninfo ul li.patronborrowernumber').text().replace(/\D/g, '');
    $.get({
        url: "/api/v1/contrib/wrm/list/" + borrowernumber,
        cache: true,
        success: function (data) {
            var cnt = 0;
            var result = $('#warehouse-requests').empty();
            result.append(`
                        <table role="grid">
                            <tbody>
                            </tbody>
                        </table>
                        `);
            if (data.length > 0) {
                result.find('table').prepend(`
                                <thead>
                                    <tr>
                                        <th>N°</th>
                                        <th>Informations</th>
                                        <th>Demandé le</th>
                                        <th>A chercher avant le</th>
                                        <th>Statut</th>
                                        <th>Site de retrait</th>
                                        <th></th>
                                    </tr>
                                </thead>
                            `);
                for (var i = 0; i < data.length; i++) {
                    console.log(data[i]);
                    var cd = new Date(data[i].created_on);
                    var rd = new Date(data[i].deadline);
                    var infoBlock = '<div><a class="strong" href="/cgi-bin/koha/catalogue/detail.pl?biblionumber=' + data[i].biblionumber + '" title="' + data[i].biblio.title + '">' + data[i].biblio.title + '</a></div>';
                    if (data[i].biblio.author != '' && data[i].biblio.author != undefined) {
                        infoBlock += '<div>' + data[i].biblio.author + '</div>';
                    }
                    if (data[i].item.itemcallnumber != '' && data[i].item.itemcallnumber != undefined) {
                        infoBlock += '<div>Cote : ' + data[i].item.itemcallnumber + '</div><div>Code-barres : ' + data[i].item.barcode + '</div>';
                    }
                    var extInfoBlock = [];
                    if (data[i].volume != '' && data[i].volume != undefined) extInfoBlock.push('<span class="label">Volume(s) : ' + data[i].volume + '</span>');
                    if (data[i].issue != '' && data[i].issue != undefined) extInfoBlock.push('<span class="label">Numéro(s) : ' + data[i].issue + '</span>');
                    if (data[i].date != '' && data[i].date != undefined) extInfoBlock.push('<span class="label">Date : ' + data[i].date + '</span>');
                    if (extInfoBlock.length > 0) infoBlock += '<br />' + extInfoBlock.join(' | ');
                    result.find('tbody').append(`
                                    <tr>
                                        <td>`+ data[i].id + `</td>
                                        <td>`+ infoBlock + `</td>
                                        <td>`+ cd.toLocaleDateString() + ' ' + cd.toLocaleTimeString() + `</td>
                                        <td>`+ rd.toLocaleDateString() + `</td>
                                        <td class="nowrap">`+ decodeURIComponent(data[i].statusstr) + `</td>
                                        <td>`+ data[i].branchname + `</td>
                                        <td class="text-center">`+
                        (['CANCELED', 'COMPLETED'].indexOf(data[i].status) < 0 ?
                            '<div class="btn-group">' +
                            (data[i].status == 'WAITING' ? '<a data-id="' + data[i].id + '" title="Terminer la demande" class="complete-wr btn-xs btn btn-success"><i class="fa fa-fw fa-check"></i> Terminer</a>' : '') +
                            '<a data-id="' + data[i].id + '" title="Annuler la demande" class="cancel-wr btn-xs btn btn-danger"><i class="fa fa-fw fa-close"></i> Annuler</a>' +
                            '</div>'
                            : '') +
                        (data[i].status == 'CANCELED' ? '<div class="reason">' + data[i].notes + '</div>' : '')
                        + `</td>
                                    </tr>
                                `);
                    if (['CANCELED', 'COMPLETED'].indexOf(data[i].status) < 0) {
                        cnt++;
                    }
                }
                $('#wrm-tab').text(cnt + ' Demandes magasin');
                $('#warehouse-requests table').dataTable($.extend(true, {}, dataTablesDefaults, {
                    "sDom": 't',
                    "aaSorting": [[0, "desc"]],
                    "aoColumnDefs": [
                        { "aTargets": [-1], "bSortable": false, "bSearchable": false }
                    ],
                    "bPaginate": false
                }));
                $('#circ_circulation .complete-wr, #pat_moremember .complete-wr').click(function () {
                    var id = $(this).attr('data-id');
                    $.ajax({
                        type: "POST",
                        url: "/api/v1/contrib/wrm/update_status",
                        data: {
                            id: id,
                            action: 'complete',
                        },
                        success: function (data) {
                            alert('La demande a été terminée avec succès');
                            refreshWarehouseRequests();
                        },
                        error: function (data) {
                            alert(data.error);
                        }
                    });
                });
                $('#circ_circulation .cancel-wr, #pat_moremember .cancel-wr').click(function () {
                    var notes = prompt('Raison de l\'annulation :');
                    if (notes !== null) {
                        var id = $(this).attr('data-id');
                        $.ajax({
                            type: "POST",
                            url: "/api/v1/contrib/wrm/update_status",
                            data: {
                                id: id,
                                action: 'cancel',
                                notes: notes,
                            },
                            success: function (data) {
                                alert('La demande a été annulée avec succès');
                                refreshWarehouseRequests();
                            },
                            error: function (data) {
                                alert(data.error);
                            }
                        });
                    }
                });
            } else {
                result.find('tbody').append('<tr><td>L\'adhérent n\'a pas de demandes magasin en cours.</td></tr>');
            }
        }
    });
}
</script>
