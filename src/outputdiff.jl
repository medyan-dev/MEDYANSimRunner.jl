# functions to show the difference between two job outputs

import DeepDiffs

"""
    hdf5_print_diff(io, group1::Union{HDF5.File, HDF5.Group}, group2::Union{HDF5.File, HDF5.Group}, group1name="group1", group2name="group2", header="", ignorename=Returns(false))

Print the difference between the HDF5 groups
"""
function hdf5_print_diff(io, group1::Union{HDF5.File, HDF5.Group}, group2::Union{HDF5.File, HDF5.Group}, group1name="group1", group2name="group2", header="", ignorename=Returns(false))
    #check both groups have same keys
    ks1 = Set(keys(group1))
    ks2 = Set(keys(group2))
    diffks1 = sort(collect(setdiff(ks1,ks2)))
    diffks2 = sort(collect(setdiff(ks2,ks1)))
    foreach(diffks1) do diffk
        ignorename(diffk) && return
        println(io,"\"$header$diffk\" in $group1name but not in $group2name")
    end
    foreach(diffks2) do diffk
        ignorename(diffk) && return
        println(io,"\"$header$diffk\" in $group2name but not in $group1name")
    end
    #check attributes are equal
	hdf5_print_attrs_diff(io, group1, group2, group1name, group2name, header, ignorename)
    sharedkeys= sort(collect(ks1 ∩ ks2))
    foreach(sharedkeys) do key
        ignorename(key) && return
        hdf5_print_diff(io, group1[key], group2[key], group1name, group2name, header*key*"/", ignorename)
    end
end

function hdf5_print_diff(io, group1::HDF5.Dataset, group2::HDF5.Dataset, group1name="group1", group2name="group2", header="", ignorename=Returns(false))
    hdf5_print_attrs_diff(io, group1, group2, group1name, group2name, header, ignorename)
    data1 = read(group1)
    data2 = read(group2)
    if !isequal(data1,data2)
		for (groupname,data) in [(group1name,data1),(group2name,data2)]
			if isempty(header)
				println(io,"read($groupname):")
			else
				println(io,"read($groupname[\"$header\"]):")
			end
			show(io,data)
			println(io)
		end
    end
end

function hdf5_print_diff(io, group1::Union{HDF5.File, HDF5.Group, HDF5.Dataset}, group2::Union{HDF5.File, HDF5.Group, HDF5.Dataset}, group1name="group1", group2name="group2", header="", ignorename=Returns(false))
	if isempty(header)
		println(io, "$group1name isa $(typeof(group1)), $group2name isa $(typeof(group2))")
	else
		println(io, "$group1name[\"$header\"] isa $(typeof(group1)), $group2name[\"$header\"] isa $(typeof(group2))")
	end
end

function hdf5_print_attrs_diff(io, group1::Union{HDF5.File, HDF5.Group, HDF5.Dataset}, group2::Union{HDF5.File, HDF5.Group, HDF5.Dataset}, group1name="group1", group2name="group2", header="", ignorename=Returns(false))
	for (groupaname,groupa,groupb) in [(group1name,group1,group2),(group2name,group2,group1)]
		diffas = sort(collect(setdiff(attrs(groupa),attrs(groupb))); by=(x->x[1]))
	    foreach(diffas) do (k,v)
            ignorename(k) && return
			if isempty(header)
				print(io,"attrs($groupaname)")
			else
				print(io,"attrs($groupaname[\"$header\"])")
			end
			print(io,"[\"$k\"] is ")
			show(io, v)
			println(io)
	    end
	end
end

"""
hdf5_show_diff(;group1 group2)
"""
function hdf5_show_diff(ignorename=Returns(false);kwargs...)
    length(kwargs) == 2 || length(kwargs) == 3 || error("must compare two groups")
    group1name = string(keys(kwargs)[1])
    group2name = string(keys(kwargs)[2])
    maxnamewidth = max(textwidth(group1name),textwidth(group2name))
    group1name = lpad(group1name, maxnamewidth)
    group2name = lpad(group2name, maxnamewidth)
    Docs.Text(io->hdf5_print_diff(io, kwargs[1], kwargs[2], group1name, group2name, "", ignorename))
end

"""
    print_json_diff(io::IO, json1::AbstractString, json2::AbstractString)

Print the difference in two json strings.
If there is no difference, nothing gets printed.
"""
function print_json_diff(io::IO, json1::AbstractString, json2::AbstractString)
    json1_pretty = sprint(JSON.pretty, JSON3.read(json1))
    json2_pretty = sprint(JSON.pretty, JSON3.read(json2))
    if json1_pretty != json2_pretty
        println(io, DeepDiffs.deepdiff(json1_pretty, json2_pretty))
    end
end


"""
    print_list_file_diff(io::IO, list1::AbstractString, list2::AbstractString)

Print the difference in two list.txt files. 

ignoring the nthreads, timestamp, and julia version info.
"""
function print_list_file_diff(io::IO, list1::AbstractString, list2::AbstractString)
    l1, _ = parse_list_file(list1)
    l2, _ = parse_list_file(list2)
    if l1.job_idx==0 || l2.job_idx==0
        # one list is empty or non existent
        if l1.job_idx==0 & l2.job_idx!=0
            println(io, list1, " file missing or empty")
        elseif l1.job_idx!=0 & l2.job_idx==0
            println(io, list2, " file missing or empty")
        end
    else
        # both exist
        for fname in (:job_idx, :input_git_tree_sha1, :final_message)
            if getproperty(l1, fname) != getproperty(l2, fname)
                println(io, list1," ",fname,": ", getproperty(l1, fname))
                println(io, list2," ",fname,": ", getproperty(l2, fname))
            end
        end
        if length(l1.snapshot_infos) != length(l2.snapshot_infos)
            println(io, list1, " has ", length(l1.snapshot_infos), "snapshots recorded")
            println(io, list1, " has ", length(l2.snapshot_infos), "snapshots recorded")
        else
            for i in eachindex(l1.snapshot_infos)
                s1 = l1.snapshot_infos[i]
                s2 = l2.snapshot_infos[i]
                for fname in (:step_number, :rngstate)
                    if getproperty(s1, fname) != getproperty(s2, fname)
                        println(io, "$list1 snapshot $i $fname: $(getproperty(s1, fname))")
                        println(io, "$list2 snapshot $i $fname: $(getproperty(s2, fname))")
                    end
                end
            end
        end
    end
end


"""
Prints the difference between two job output directories.

Ignores time stamp differences and julia version differences in the list.txt file.

# Args

- `job_output_dir_1`: The first output directory.
- `job_output_dir_2`: The second output directory.

"""
function print_output_diff(io::IO, jobout1::AbstractString, jobout2::AbstractString)

    isdir(jobout1) || throw(ArgumentError("$job_output_dir_1 path not found"))
    isdir(jobout2) || throw(ArgumentError("$job_output_dir_2 path not found"))

    # header.json
    header1 = joinpath(jobout1,"header.json")
    header2 = joinpath(jobout2,"header.json")
    if isfile(header1) & isfile(header2)
        print_json_diff(io, read(header1, String), read(header2, String))
    elseif isfile(header1) & !isfile(header2)
        println(io, header2, " file missing")
    elseif !isfile(header1) & isfile(header2)
        println(io, header1, " file missing")
    else
    end

    # list.txt
    list1 = joinpath(jobout1,"list.txt")
    list2 = joinpath(jobout2,"list.txt")
    print_list_file_diff(io, list1, list2)

    # snapshots sub dir
    snapshots1 = readdir(joinpath(jobout1, "snapshots"); join=true)
    snapshots2 = readdir(joinpath(jobout2, "snapshots"); join=true)

end