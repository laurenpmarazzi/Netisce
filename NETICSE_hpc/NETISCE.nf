#!/usr/bin/env nextflow

params.expressions = "$baseDir/input_data/expressions.csv"
params.network = "$baseDir/input_data/network.sif"
params.samples = "$baseDir/input_data/samples.txt"
params.internal_control="$baseDir/input_data/internal_marker.txt"
params.alpha = 0.9
params.undesired = 'resistant'
params.desired = 'sensitive'
params.filter ="strict"


params.kmeans_min_val = 2
params.kmeans_max_val = 10


params.num_nodes = 4
params.num_states = 1000


process sfa_exp {
    input: 
    path "expressions.csv" from params.expressions
    path "network.sif" from params.network

    output: 
    path 'attrs_exp.txt' into records_expattr

    script:
    """
    SFA_exp_attr.py network.sif expressions.csv attrs_exp.txt
    """
}

process get_exp_internal_control_nodes {  
    publishDir 'results', mode: 'copy', overwrite: true
    
    input:
    path 'attrs_exp.txt' from records_expattr
    path "internal_marker.txt" from params.internal_control

    output:
    path 'exp_internalmarkers.txt' into records_exp_icns
    
    script:
    """
    get_RONs.py attrs_exp.txt internal_marker.txt
    """
    
}



process insilico_inits {

    output: 
    path 'init.txt' into records_insilicoinit

    script:
    """
    generate_basal_states.py $params.num_states $params.num_nodes init.txt attr -1,0,1
    """
}
process insilico {
    input:
    path 'expressions.csv' from params.expressions
    path 'network.sif' from params.network
    path 'samples.txt' from params.samples
    path 'init.txt' from records_insilicoinit
 
    output:
    path 'attrs_insilico*' into records_insilico
 
    script:
 
    """
    SFA_insilico.py "network.sif" "expressions.csv" "samples.txt" init.txt $params.alpha
    """
}

process getFVS {
    publishDir 'results', mode: 'copy', overwrite: true

    input:
    path 'network.sif' from params.network
 
    output:
    path 'fvs.txt' into records_fvs
    script:
    """
    FVS_run.py network.sif
    """
}
process perturbation_inits {
    input:
    path "fvs.txt" from records_fvs
    // path 'fvs.txt' from records3a
    
    output:
    path 'fvs_init.txt' into records_pert_inits
    

    script:
    """
    generate_perts.py fvs.txt fvs_init.txt pert -1,0,1
    """
}
process sfa_perts {
    input:
    path 'expressions.csv' from params.expressions
    path 'network.sif' from params.network
    path 'samples.txt' from params.samples
    path "fvs.txt" from records_fvs
    path 'fvs_init.txt' from records_pert_inits
 
    output:
    path 'pert*' into records_perts
 
    script:
    """
    SFA_virtscreen.py network.sif expressions.csv $params.undesired samples.txt fvs.txt fvs_init.txt $params.alpha
    
    """
}

process check_icns{
    publishDir 'results', mode: 'copy', overwrite: true
    input:
    path 'exp_internalmarkers.txt' from records_exp_icns
    path 'samples.txt' from params.samples

    output:
    path 'experimental_internalmarkers.pdf' into records_icn_check

    script:
    """
    module load R/3.6.3
    icn_check1.R exp_internalmarkers.txt samples.txt
    """
    
}

process kmeans_opt {
    publishDir 'results', mode: 'copy', overwrite: true

    input:
    path 'attrs_exp.txt' from records_expattr
    path 'attrs_insilico*' from records_insilico
 
    output:
    env ELBOW into records_elbow
    env SILHOUETTE into records_silhouette
    path '*.pdf' into records_silplots
    path '*.png' into records_elbowplots
    
    shell:
    """
    datasets=\$(ls -m attr* | sed 's/ //g')
    echo \$datasets
    export SILHOUETTE=\$(silhouette_metric.py \$datasets results/ $params.kmeans_max_val)
    export ELBOW=\$(elbow_metric.py \$datasets results/ $params.kmeans_max_val)
    """
}
process kmeans {
    input:
    val ELBOW from records_elbow
    val SILHOUETTE from records_silhouette
    path 'attrs_exp.txt' from records_expattr
    path 'attrs_insilico*' from records_insilico
    path 'samples.txt' from params.samples

    output:
    path 'kmeans.txt' into records_kmeans

    script:
    if (ELBOW==SILHOUETTE)
        """
        datasets=\$(ls -m attr* | sed 's/ //g')
        kmeans.py $ELBOW \$datasets
        """

    else if (ELBOW<SILHOUETTE)
        """
        datasets=\$(ls -m attr* | sed 's/ //g')
        kmeans.py $ELBOW \$datasets
        """
    else if (SILHOUETTE<ELBOW)
        """
        datasets=\$(ls -m attr* | sed 's/ //g')
        kmeans.py $SILHOUETTE \$datasets
        """

}

process classification {
    input:
    path 'kmeans.txt' from records_kmeans
    path 'pert*' from records_perts
    path 'samples.txt' from params.samples
    path 'attrs_exp.txt' from records_expattr
    path 'attrs_insilico*' from records_insilico
    output:
    path 'class_*' into records_classification
    
    script:
    """
    export train=\$(ls -m attr* | sed 's/ //g')
    for x in pert*
    do
        NB.py \$train \$x kmeans.txt 
        RF.py \$train \$x kmeans.txt
        SVM.py \$train \$x kmeans.txt
    done
    """
}

process consensus {
    publishDir 'results', mode: 'copy', overwrite: true
    input:
    path '*' from records_classification
    path 'kmeans.txt' from records_kmeans
    path 'samples.txt' from params.samples
    
    output:
    path 'crit1perts.txt' into records_consensus
    
    script:
    """
    datasets=\$(ls -m class_* | tr -d '[:space:]')

    export desired_sample=\$(grep $params.desired samples.txt | head -1 | sed 's/\t.*//')
    export desired_cluster=\$(grep \$desired_sample kmeans.txt | head -1 | sed 's/.*\s//')
    get_clusterconsensus.py \$datasets \$desired_cluster
    """
    
}

process internal_control_node_analysis {  
    publishDir 'results', mode: 'copy', overwrite: true    
    input:
    path 'pert*' from records_perts
    path 'crit1perts.txt' from records_consensus
    path "internal_marker.txt" from params.internal_control
    
    output:
    path '*_internal_markers.txt' into records_pert_icns
    
    script:
    """
    for x in pert*
    do
    echo \$x
    get_RONs_getperts.py \$x "internal_marker.txt" 'crit1perts.txt'
    done
    """
    
}


process filtering_by_icn {      
    input:
    path 'exp_internalmarkers.txt' from records_exp_icns
    path 'pert_logss*' from records_pert_icns
    path 'samples.txt' from params.samples

    output:
    path '*_filtered_perturbations.txt' into records_filtered_perts
    
    script:
    """
    module load R/3.6.3
    for x in pert_logss*
    do
    crit2.R exp_internalmarkers.txt samples.txt \$x $params.desired $params.undesired $params.filter
    done
    """
    
}

process extract_perts {  
    
    input:
    path 'fvs_init.txt' from records_pert_inits
    path "fvs.txt" from records_fvs
    path '*_filtered_perturbations.txt' from records_filtered_perts


    output:
    path 'extract_perts.txt' into records_extracted_perts
    
    script:
    """
    for x in *_filtered_perturbations.txt
    do
    get_perts.py fvs_init.txt fvs.txt \$x
    done
    """
    
}

process translate_perts {  
    publishDir 'results', mode: 'copy', overwrite: true
    
    input:
    path 'extract_perts.txt' from records_extracted_perts


    output:
    path 'successful_controlnode_perturbations.txt' into records_translated_perts
    
    script:
    """
    module load R/3.6.3
    pertanalysis.R extract_perts.txt
    """
    
}


