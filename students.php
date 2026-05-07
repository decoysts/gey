<?php
session_start();
require "dbconnect.php";

// Проверка авторизации
if (!isset($_SESSION['verified']) || $_SESSION['verified'] != '1') {
    header("Location: auth.php");
    exit();
}

echo "<center><h2>STUDENTS LIST</h2></center>";

$query = "SELECT * FROM students";
$result = $conn->query($query);

echo "<table border='1' cellpadding='5'>";
echo "<tr><th>First Name</th><th>Last Name</th><th>Surname</th></tr>";

while ($row = $result->fetch_assoc()) {
    echo "<tr>";
    echo "<td>" . htmlspecialchars($row['firstname']) . "</td>";
    echo "<td>" . htmlspecialchars($row['lastname']) . "</td>";
    echo "<td>" . htmlspecialchars($row['surname']) . "</td>";
    echo "</tr>";
}

echo "</table>";

echo "<br><br>";
echo '<form action="logout.php">
        <button type="submit">Logout</button>
      </form>';
?>
