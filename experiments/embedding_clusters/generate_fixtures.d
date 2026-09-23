/// Generate the authored CC0 embedding/cluster feasibility corpus.
module experiments.embedding_clusters.generate_fixtures;

import domain.document : DocumentId, SourceLocator;
import std.file : mkdirRecurse, write;
import std.path : buildPath;

private struct Record {
    string key;
    string split;
    string text;
}

private struct Judgment {
    string key;
    string split;
    string left;
    string right;
    string label;
}

private DocumentId idFor(string key) {
    return DocumentId.from(SourceLocator("embedding-clusters:v1",
        "authored-cc0", key));
}

void main(string[] arguments) {
    const root = arguments.length == 2 ? arguments[1] :
        "experiments/embedding_clusters/fixtures";
    mkdirRecurse(root);

    immutable records = [
        Record("tr01", "train", "The city council approved a solar panel program for public schools."),
        Record("tr02", "train", "The city council approved a solar panel program for public schools."),
        Record("tr03", "train", "Bake the bread at 220 degrees for thirty minutes, then cool it on a rack."),
        Record("tr04", "train", "Bake bread for 30 minutes at 220 degrees and let the loaf cool on a rack."),
        Record("tr05", "train", "Volunteers rescued the lost dog beside the northern railway station."),
        Record("tr06", "train", "A lost dog was rescued by volunteers near the north train station."),
        Record("tr07", "train", "Rooftop solar arrays reduce a building's daytime electricity demand."),
        Record("tr08", "train", "Battery storage lets homes use renewable power after sunset."),
        Record("tr09", "train", "Drip irrigation sends small amounts of water directly to plant roots."),
        Record("tr10", "train", "Gardeners conserve water by covering soil with organic mulch."),
        Record("tr11", "train", "Frequent buses can reduce traffic congestion in crowded city centers."),
        Record("tr12", "train", "Protected bicycle lanes give commuters an alternative to driving."),
        Record("tr13", "train", "A violin maker selected aged maple for the instrument's back."),
        Record("tr14", "train", "The database replica completed its nightly transaction log backup."),
        Record("tr15", "train", "Marine biologists counted seals along the rocky island shore."),
        Record("tr16", "train", "The pastry chef folded orange zest into the chocolate batter."),
        Record("tr17", "train", "A jaguar moved silently through the rainforest before dawn."),
        Record("tr18", "train", "The Jaguar sedan received a redesigned electric powertrain."),
        Record("ho01", "heldout", "The library will remain closed on Monday while workers repair the roof."),
        Record("ho02", "heldout", "The library will remain closed on Monday while workers repair the roof."),
        Record("ho03", "heldout", "Flights were cancelled after heavy snow covered the airport runway."),
        Record("ho04", "heldout", "Heavy snowfall covered the runway, causing the airport to cancel flights."),
        Record("ho05", "heldout", "The museum opened a new exhibition of early landscape photographs."),
        Record("ho06", "heldout", "A new show of historic landscape photography opened at the museum."),
        Record("ho07", "heldout", "Vaccination trains the immune system to recognize a pathogen."),
        Record("ho08", "heldout", "Booster doses can strengthen protection when immunity declines."),
        Record("ho09", "heldout", "To make stock, simmer vegetables and herbs slowly in water."),
        Record("ho10", "heldout", "Roasting onions and carrots deepens the flavor of a winter soup."),
        Record("ho11", "heldout", "Multi-factor authentication reduces the risk from stolen passwords."),
        Record("ho12", "heldout", "Security teams rotate access keys after a credential leak."),
        Record("ho13", "heldout", "The pianist practiced the difficult sonata passage at half speed."),
        Record("ho14", "heldout", "A weather satellite entered orbit aboard the launch vehicle."),
        Record("ho15", "heldout", "The cafe served coffee roasted from beans grown in Guatemala."),
        Record("ho16", "heldout", "Geologists mapped a fault beneath the desert basin."),
        Record("ho17", "heldout", "The bank approved a loan for the neighborhood bakery."),
        Record("ho18", "heldout", "Willows grew along the muddy bank of the river."),
    ];

    immutable judgments = [
        Judgment("train-dup-1", "train", "tr01", "tr02", "duplicate"),
        Judgment("train-dup-2", "train", "tr03", "tr04", "duplicate"),
        Judgment("train-dup-3", "train", "tr05", "tr06", "duplicate"),
        Judgment("train-rel-1", "train", "tr07", "tr08", "related"),
        Judgment("train-rel-2", "train", "tr09", "tr10", "related"),
        Judgment("train-rel-3", "train", "tr11", "tr12", "related"),
        Judgment("train-unrel-1", "train", "tr13", "tr14", "unrelated"),
        Judgment("train-unrel-2", "train", "tr15", "tr16", "unrelated"),
        Judgment("train-abstain-1", "train", "tr17", "tr18", "abstain"),
        Judgment("heldout-dup-1", "heldout", "ho01", "ho02", "duplicate"),
        Judgment("heldout-dup-2", "heldout", "ho03", "ho04", "duplicate"),
        Judgment("heldout-dup-3", "heldout", "ho05", "ho06", "duplicate"),
        Judgment("heldout-rel-1", "heldout", "ho07", "ho08", "related"),
        Judgment("heldout-rel-2", "heldout", "ho09", "ho10", "related"),
        Judgment("heldout-rel-3", "heldout", "ho11", "ho12", "related"),
        Judgment("heldout-unrel-1", "heldout", "ho13", "ho14", "unrelated"),
        Judgment("heldout-unrel-2", "heldout", "ho15", "ho16", "unrelated"),
        Judgment("heldout-abstain-1", "heldout", "ho17", "ho18", "abstain"),
    ];

    DocumentId[string] ids;
    string corpus = "id\tsplit\ttext\n";
    foreach (record; records) {
        auto id = idFor(record.key);
        ids[record.key] = id;
        corpus ~= id.text ~ "\t" ~ record.split ~ "\t" ~ record.text ~ "\n";
    }
    write(buildPath(root, "corpus.tsv"), corpus);

    string train = "judgment\tleft_id\tright_id\tlabel\n";
    string heldout = train;
    foreach (judgment; judgments) {
        auto line = judgment.key ~ "\t" ~ ids[judgment.left].text ~ "\t" ~
            ids[judgment.right].text ~ "\t" ~ judgment.label ~ "\n";
        if (judgment.split == "train")
            train ~= line;
        else
            heldout ~= line;
    }
    write(buildPath(root, "labels-train.tsv"), train);
    write(buildPath(root, "labels-heldout.tsv"), heldout);
}
