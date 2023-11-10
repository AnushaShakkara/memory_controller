module testbench;

initial begin

integer file;
string input_file, output_file;
integer time_t, core, operation, address;

if ($value$plusargs ("input_file=%s", input_file))
    $display ("user entered input file name: %s", input_file);
else
    begin
        input_file = "trace.txt";
        $display("User using default input file: %s",input_file);
    end

if ($value$plusargs ("output_file=%s", output_file))
    $display ("user entered output file name: %s", output_file);
else
    begin
        output_file = "dram.txt";
        $display("using default output file: %s",output_file);
    end

file = ProcessFile(input_file,"r");
ParseInputFile(file, input_file);
$fclose(file);

file = ProcessFile(output_file,"w");
$fclose(file);

end



/***************************** Function definitions *******************************/


function void ParseInputFile (integer file, string input_file);
begin
    integer time_t, core, operation, address;
    $display("Parsing %s:\n\n",input_file);
    while (!$feof(file))
    begin
        $fscanf (file,"%d %d %d %h", time_t, core, operation, address);
        `ifdef DEBUG
        $display ("%d %d %d\t %h",time_t, core, operation, address);
        `endif
    end
    $display("\nParsing complete!");
end
endfunction


function integer ProcessFile (string file_name, string mode);
begin
    ProcessFile = $fopen(file_name,mode);
    if (!ProcessFile)
        $display("Unable to open the file!");
    
end
endfunction

endmodule